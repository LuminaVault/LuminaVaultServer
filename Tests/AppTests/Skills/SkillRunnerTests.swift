@testable import App
import FluentKit
import FluentPostgresDriver
import Foundation
import HummingbirdFluent
import Logging
import SQLKit
import Testing

@Suite(.serialized)
struct SkillRunnerTests {
    private static func withHarness<T: Sendable>(
        _ body: @Sendable (Harness) async throws -> T,
    ) async throws -> T {
        let fluent = Fluent(logger: Logger(label: "test.skill-runner"))
        fluent.databases.use(.postgres(configuration: TestPostgres.configuration()), as: .psql)
        await fluent.migrations.add(M00_EnableExtensions())
        await fluent.migrations.add(M01_CreateUser())
        await fluent.migrations.add(M06_CreateMemory())
        await fluent.migrations.add(M07_AddMemoryEmbedding())
        await fluent.migrations.add(M09_AddUsernameToUser())
        await fluent.migrations.add(M10_CreateDeviceToken())
        await fluent.migrations.add(M12_CreateSpace())
        await fluent.migrations.add(M13_CreateVaultFile())
        await fluent.migrations.add(M15_AddTierFields())
        await fluent.migrations.add(M18_AddMemoryTags())
        await fluent.migrations.add(M19_CreateSkillsState())
        await fluent.migrations.add(M20_CreateSkillRunLog())
        await fluent.migrations.add(M21_AddMemoryScore())
        await fluent.migrations.add(M23_AddMemorySourceLineage())
        await fluent.migrations.add(M24_AddUserContextRouting())
        await fluent.migrations.add(M25_AddUserPrivacyNoCNOrigin())
        await fluent.migrations.add(M26_AddSkillsStateDailyRunCap())
        await fluent.migrations.add(M27_AddUserTimezone())
        try await fluent.migrate()

        let tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("lv-skill-runner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)

        let username = "skill-\(UUID().uuidString.prefix(8).lowercased())"
        let user = User(
            email: "\(username)@test.luminavault",
            username: username,
            passwordHash: "x",
        )
        try await user.save(on: fluent.db())

        do {
            let result = try await body(Harness(
                fluent: fluent,
                tenantID: user.requireID(),
                username: username,
                root: tmpRoot,
            ))
            try? await fluent.shutdown()
            try? FileManager.default.removeItem(at: tmpRoot)
            return result
        } catch {
            try? await fluent.shutdown()
            try? FileManager.default.removeItem(at: tmpRoot)
            throw error
        }
    }

    @Test
    func `disallowed tool returns tool error and does not write memory`() async throws {
        try await Self.withHarness { h in
            let transport = SkillScriptedTransport(steps: [
                .toolCall(name: "memory_upsert", arguments: #"{"content":"must not persist"}"#),
                .plainContent("I could not write that memory."),
            ])
            let runner = Self.makeRunner(h, transport: transport)
            let manifest = Self.manifest(
                name: "deny-memory",
                allowedTools: ["session_search"],
                outputs: [],
            )

            let result = try await runner.run(
                skill: manifest,
                tenantID: h.tenantID,
                profileUsername: h.username,
                trigger: .manual,
            )

            #expect(result.status == "ok")
            let rows = try await Memory.query(on: h.fluent.db(), tenantID: h.tenantID).all()
            #expect(rows.isEmpty)

            let calls = await transport.calls
            #expect(calls.count == 2)
            let secondPayload = try Self.decodePayload(calls[1].payload)
            let messages = try #require(secondPayload["messages"] as? [[String: Any]])
            let toolMessage = try #require(messages.last)
            #expect(toolMessage["role"] as? String == "tool")
            let content = try #require(toolMessage["content"] as? String)
            #expect(content.contains("\"status\":\"error\""))
            #expect(content.contains("not allowed"))
        }
    }

    @Test
    func `dispatches every output kind`() async throws {
        try await Self.withHarness { h in
            let source = VaultFile(
                tenantID: h.tenantID,
                path: "inbox/source.md",
                contentType: "text/markdown",
                sizeBytes: 5,
                sha256: "old",
            )
            try await source.save(on: h.fluent.db())
            let sourceID = try source.requireID()
            let sourceURL = h.rawRoot
                .appendingPathComponent("inbox", isDirectory: true)
                .appendingPathComponent("source.md")
            try FileManager.default.createDirectory(at: sourceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("old".utf8).write(to: sourceURL)

            try await DeviceToken(tenantID: h.tenantID, token: "token-\(UUID().uuidString)", platform: "ios").save(on: h.fluent.db())
            let push = RecordingPushSender()
            let transport = SkillScriptedTransport(steps: [
                .plainContent("Enriched skill output."),
            ])
            let runner = Self.makeRunner(h, transport: transport, push: push)
            let manifest = Self.manifest(
                name: "dispatch-all",
                allowedTools: ["memory_upsert"],
                outputs: [
                    .init(kind: .memo, path: "memos/skill.md", category: nil),
                    .init(kind: .apnsDigest, path: nil, category: nil),
                    .init(kind: .apnsNudge, path: nil, category: nil),
                    .init(kind: .memoryEmit, path: nil, category: nil),
                    .init(kind: .vaultRewrite, path: nil, category: nil),
                ],
            )

            let result = try await runner.run(
                skill: manifest,
                tenantID: h.tenantID,
                profileUsername: h.username,
                trigger: .event(
                    name: "vault_file_created",
                    payload: [SkillEvent.PayloadKey.sourceVaultFileID: sourceID.uuidString],
                ),
            )

            #expect(result.status == "ok")
            let memoPath = h.rawRoot.appendingPathComponent("memos/skill.md")
            #expect(try String(contentsOf: memoPath, encoding: .utf8) == "Enriched skill output.")
            let memoRow = try await VaultFile.query(on: h.fluent.db(), tenantID: h.tenantID)
                .filter(\.$path == "memos/skill.md")
                .first()
            #expect(memoRow != nil)

            let sends = await push.sends
            #expect(sends.map(\.category).sorted { $0.rawValue < $1.rawValue } == [.digest, .nudge])

            let memories = try await Memory.query(on: h.fluent.db(), tenantID: h.tenantID).all()
            #expect(memories.count == 1)
            #expect(memories[0].content == "Enriched skill output.")

            #expect(try String(contentsOf: sourceURL, encoding: .utf8) == "Enriched skill output.")
            let rewritten = try await VaultFile.query(on: h.fluent.db(), tenantID: h.tenantID)
                .filter(\.$id == sourceID)
                .first()
            #expect(rewritten?.sizeBytes == Int64("Enriched skill output.".utf8.count))
        }
    }

    @Test
    func `records usage counters from provider metadata`() async throws {
        try await Self.withHarness { h in
            let transport = SkillScriptedTransport(
                steps: [.plainContent("Done.")],
                metadata: .init(data: Data(), headers: [
                    "x-mtok-in": "12",
                    "x-mtok-out": "34",
                ]),
            )
            let runner = Self.makeRunner(h, transport: transport)
            let manifest = Self.manifest(name: "usage", allowedTools: [], outputs: [])

            let result = try await runner.run(
                skill: manifest,
                tenantID: h.tenantID,
                profileUsername: h.username,
                trigger: .manual,
            )

            #expect(result.mtokIn == 12)
            #expect(result.mtokOut == 34)

            guard let sql = h.fluent.db() as? any SQLDatabase else {
                Issue.record("expected SQL database")
                return
            }
            struct Row: Decodable {
                let mtokIn: Int
                let mtokOut: Int
                enum CodingKeys: String, CodingKey {
                    case mtokIn = "mtok_in"
                    case mtokOut = "mtok_out"
                }
            }
            let row = try await sql.raw("""
            SELECT mtok_in, mtok_out FROM skill_run_log
            WHERE id = \(bind: result.runID)
            """).first(decoding: Row.self)
            #expect(row?.mtokIn == 12)
            #expect(row?.mtokOut == 34)
        }
    }

    private struct Harness {
        let fluent: Fluent
        let tenantID: UUID
        let username: String
        let root: URL

        var rawRoot: URL {
            root.appendingPathComponent("vault")
                .appendingPathComponent("tenants")
                .appendingPathComponent(tenantID.uuidString)
                .appendingPathComponent("raw")
        }
    }

    private static func makeRunner(
        _ h: Harness,
        transport: any HermesChatTransport,
        push: (any APNSPushSender)? = nil,
    ) -> SkillRunner {
        let vaultPaths = VaultPathService(rootPath: h.root.appendingPathComponent("vault").path)
        let apns = push.map {
            APNSNotificationService(
                bundleID: "com.luminavault.test",
                fluent: h.fluent,
                pushSender: $0,
                logger: Logger(label: "test.skill-runner.apns"),
            )
        } ?? APNSNotificationService(
            enabled: false,
            bundleID: "",
            teamID: "",
            keyID: "",
            privateKeyPath: "",
            environment: "development",
            fluent: h.fluent,
            logger: Logger(label: "test.skill-runner.apns"),
        )
        return SkillRunner(
            catalog: SkillCatalog(vaultPaths: vaultPaths, logger: Logger(label: "test.skill-catalog")),
            transport: transport,
            memories: MemoryRepository(fluent: h.fluent),
            embeddings: DeterministicEmbeddingService(),
            apns: apns,
            defaultModel: "test-model",
            fluent: h.fluent,
            vaultPaths: vaultPaths,
            capGuard: SkillRunCapGuard(fluent: h.fluent, logger: Logger(label: "test.skill-cap")),
            eventBus: EventBus(logger: Logger(label: "test.skill-events")),
            logger: Logger(label: "test.skill-runner"),
        )
    }

    private static func manifest(
        name: String,
        allowedTools: [String],
        outputs: [SkillManifest.Output],
    ) -> SkillManifest {
        SkillManifest(
            source: .builtin,
            name: name,
            description: "test skill",
            allowedTools: allowedTools,
            capability: .low,
            schedule: nil,
            onEvent: [],
            outputs: outputs,
            dailyRunCap: nil,
            body: "Run the test skill.",
        )
    }

    private static func decodePayload(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

private actor SkillScriptedTransport: HermesChatTransport {
    enum Step {
        case toolCall(name: String, arguments: String)
        case plainContent(String)
    }

    struct Call {
        let profileUsername: String
        let payload: Data
    }

    private let steps: [Step]
    private let metadata: HermesChatTransportMetadata?
    private(set) var calls: [Call] = []
    private var index = 0

    init(steps: [Step], metadata: HermesChatTransportMetadata? = nil) {
        self.steps = steps
        self.metadata = metadata
    }

    nonisolated func chatCompletions(payload: Data, profileUsername: String) async throws -> Data {
        try await chatCompletionsWithMetadata(payload: payload, profileUsername: profileUsername).data
    }

    nonisolated func chatCompletionsWithMetadata(
        payload: Data,
        profileUsername: String,
    ) async throws -> HermesChatTransportMetadata {
        try await record(payload: payload, profileUsername: profileUsername)
    }

    private func record(payload: Data, profileUsername: String) throws -> HermesChatTransportMetadata {
        calls.append(.init(profileUsername: profileUsername, payload: payload))
        guard index < steps.count else {
            throw SkillScriptedTransportError.scriptExhausted
        }
        let step = steps[index]
        index += 1
        let data = Self.encode(step)
        if let metadata {
            return .init(data: data, headers: metadata.headers)
        }
        return .init(data: data, headers: [:])
    }

    private static func encode(_ step: Step) -> Data {
        switch step {
        case let .toolCall(name, arguments):
            Data("""
            {"id":"chatcmpl-test","model":"test-model","choices":[{"index":0,"message":{"role":"assistant","content":null,"tool_calls":[{"id":"call_1","type":"function","function":{"name":"\(name)","arguments":\(String(reflecting: arguments))}}]},"finish_reason":"tool_calls"}]}
            """.utf8)
        case let .plainContent(content):
            Data("""
            {"id":"chatcmpl-test","model":"test-model","choices":[{"index":0,"message":{"role":"assistant","content":\(String(reflecting: content))},"finish_reason":"stop"}]}
            """.utf8)
        }
    }
}

private enum SkillScriptedTransportError: Error {
    case scriptExhausted
}
