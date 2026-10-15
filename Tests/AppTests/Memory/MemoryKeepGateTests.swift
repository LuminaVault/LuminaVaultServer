@testable import App
import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import HummingbirdTesting
import LuminaVaultShared
import SQLKit
import Testing

/// The keep gate decides which assistant replies become memories. What has
/// to hold: a reply judged not durable leaves no memory, a kept one carries
/// the judge's kind, and a judge that fails keeps the reply (never loses one).
///
/// Run with `docker compose up -d postgres`.
@Suite(.serialized, .tags(.integration), .integrationDatabase, .disabled(if: IntegrationTestEnv.skipIntegration))
struct MemoryKeepGateTests {
    /// Verdict by marker in the reply text; anything else is kept, so jobs
    /// from other suites in the shared database are left as they would be.
    private struct StubJudge: MemoryKeepJudge {
        struct Broken: Error {}
        func judge(content: String, tenantID _: UUID) async throws -> MemoryKeepDecision {
            if content.contains("[smalltalk]") {
                return .init(keep: false, kind: nil)
            }
            if content.contains("[decision]") {
                return .init(keep: true, kind: .decision)
            }
            if content.contains("[broken]") {
                throw Broken()
            }
            return .keepUnclassified
        }
    }

    private struct JobRow: Decodable { let status: String }

    private static func register(client: some TestClientProtocol) async throws -> UUID {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        let body = ByteBuffer(
            string: #"{"email":"keep-\#(suffix)@test.luminavault","username":"keep\#(suffix)","password":"CorrectHorseBatteryStaple1!"}"#
        )
        return try await client.execute(
            uri: "/v1/auth/register",
            method: .post,
            headers: [.contentType: "application/json"],
            body: body
        ) { try testJSONDecoder().decode(AuthResponse.self, from: Data($0.body.readableBytesView)).userId }
    }

    /// Enqueues one reply and drains the queue until that job is handled.
    private static func index(
        _ content: String,
        tenantID: UUID,
        fluent: Fluent
    ) async throws -> (status: String, memory: Memory?) {
        let sourceID = UUID().uuidString
        try await MemoryProvenanceRepository(fluent: fluent).enqueueOutput(
            tenantID: tenantID, source: .chat, sourceID: sourceID,
            conversationMessageID: nil, content: content, provider: "test", model: "test-model"
        )
        let worker = MemoryIndexWorker(
            fluent: fluent,
            embeddings: DeterministicEmbeddingService(),
            keepJudge: StubJudge()
        )
        let sql = try #require(fluent.db() as? any SQLDatabase)
        var status = "pending"
        for _ in 0 ..< 50 where status == "pending" || status == "processing" {
            try await worker.tick()
            status = try await sql.raw("""
            SELECT status FROM memory_index_jobs
            WHERE tenant_id = \(bind: tenantID) AND source_id = \(bind: sourceID)
            """).first(decoding: JobRow.self)?.status ?? "missing"
        }
        let memory = try await Memory.query(on: fluent.db(), tenantID: tenantID)
            .filter(\.$originSourceID == sourceID)
            .first()
        return (status, memory)
    }

    @Test
    func `small talk is skipped, a decision is kept with its kind, a broken judge keeps the reply`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let tenantID = try await Self.register(client: client)
            try await withTestFluent(label: "test.keep.gate") { fluent in
                let smalltalk = try await Self.index("[smalltalk] You're welcome!", tenantID: tenantID, fluent: fluent)
                #expect(smalltalk.status == "skipped")
                #expect(smalltalk.memory == nil)

                let decision = try await Self.index("[decision] You chose Postgres for the queue.", tenantID: tenantID, fluent: fluent)
                #expect(decision.status == "completed")
                #expect(decision.memory?.kind == "decision")

                let broken = try await Self.index("[broken] Something useful.", tenantID: tenantID, fluent: fluent)
                #expect(broken.status == "completed")
                #expect(broken.memory != nil, "a failing judge must not lose the reply")
                #expect(broken.memory?.kind == nil)
            }
        }
    }

    @Test
    func `the verdict parser fails open on anything unusable`() {
        #expect(LLMMemoryKeepJudge.parse(#"{"keep":false,"kind":null}"#) == .init(keep: false, kind: nil))
        #expect(LLMMemoryKeepJudge.parse(#"Sure. {"keep":true,"kind":"preference"}"#) == .init(keep: true, kind: .preference))
        #expect(LLMMemoryKeepJudge.parse(#"{"keep":false,"kind":"preference"}"#)?.kind == nil, "a dropped reply has no kind")
        #expect(LLMMemoryKeepJudge.parse("no idea") == nil)
    }
}
