@testable import App
import FluentKit
import Foundation
import HummingbirdFluent
import Logging
import LuminaVaultShared
import Testing

/// `GET /v1/hermes/artifacts?sessionID=` — how a chat surface shows only the
/// artifacts produced by the run backing the conversation on screen.
///
/// Artifacts are keyed by Hermes session, not by conversation, so the join is
/// conversation → run.sessionID → artifacts. That is why the filter takes a
/// session id and not a conversation id.
///
/// Requires `docker compose up -d postgres`.
@Suite(.serialized, .tags(.integration), .integrationDatabase, .disabled(if: IntegrationTestEnv.skipIntegration))
struct HermesArtifactsFilterTests {
    private static let logger = Logger(label: "test.hermes-artifacts-filter")

    private actor NoTransports: HermesMirrorTransportProviding {
        nonisolated func kind(tenantID _: UUID) async -> HermesMirrorTransportKind {
            .remote
        }

        func transport(tenantID _: UUID) async throws -> any HermesMirrorTransport {
            // Listing reads Postgres only; reaching the network here means
            // the read path regressed into a remote call.
            throw HermesMirrorTransportError.unsupported("listing must not hit the network")
        }
    }

    private struct FixedEmbedding: EmbeddingService {
        func embed(_: String, tenantID _: UUID) async throws -> [Float] {
            [Float](repeating: 0.01, count: 1536)
        }
    }

    private static func makeService(fluent: Fluent) -> HermesMirrorService {
        let vaultRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("lv-artifact-filter-\(UUID().uuidString)", isDirectory: true)
        let vaultPaths = VaultPathService(rootPath: vaultRoot.path)
        return HermesMirrorService(
            fluent: fluent,
            transports: NoTransports(),
            capabilities: nil,
            ingest: VaultIngestService(
                fluent: fluent,
                vaultPaths: vaultPaths,
                spaces: SpacesService(fluent: fluent, vaultPaths: vaultPaths, logger: logger),
                memories: MemoryRepository(fluent: fluent),
                embeddings: FixedEmbedding(),
                logger: logger
            ),
            compile: nil,
            bundledSkills: HermesBundledSkills(root: nil),
            logger: logger
        )
    }

    private static func seedTenant(on fluent: Fluent) async throws -> UUID {
        let id = UUID()
        let username = "art\(UUID().uuidString.prefix(6).lowercased())"
        try await User(id: id, email: "\(username)@test.luminavault", username: username, passwordHash: "stub")
            .save(on: fluent.db())
        try await Vault(id: id, personalOwnerUserID: id, name: "Personal").save(on: fluent.db())
        return id
    }

    private static func seedArtifact(
        on fluent: Fluent,
        tenantID: UUID,
        sessionID: String,
        label: String,
        occurredAt: Date
    ) async throws {
        let record = HermesArtifactExtractor.Record(
            kind: .link,
            value: "https://example.com/\(label)",
            href: "https://example.com/\(label)",
            label: label,
            sessionID: sessionID,
            sessionTitle: "session \(sessionID)",
            occurredAt: occurredAt,
            contentHash: UUID().uuidString
        )
        try await HermesArtifact(tenantID: tenantID, record: record).save(on: fluent.db())
    }

    @Test("Filtering by session returns only that session's artifacts")
    func filtersToOneSession() async throws {
        try await withTestFluent(label: "test.hermes.artifacts.filter") { fluent in
            await registerMigrations(on: fluent)
            try await fluent.migrate()
            let tenantID = try await Self.seedTenant(on: fluent)
            let service = Self.makeService(fluent: fluent)
            let base = Date(timeIntervalSince1970: 1_700_000_000)

            try await Self.seedArtifact(on: fluent, tenantID: tenantID, sessionID: "sess-a", label: "one", occurredAt: base)
            try await Self.seedArtifact(on: fluent, tenantID: tenantID, sessionID: "sess-a", label: "two", occurredAt: base.addingTimeInterval(1))
            try await Self.seedArtifact(on: fluent, tenantID: tenantID, sessionID: "sess-b", label: "other", occurredAt: base.addingTimeInterval(2))

            let filtered = try await service.artifacts(
                tenantID: tenantID, kind: nil, query: nil, before: nil, limit: 50, sessionID: "sess-a"
            )
            #expect(Set(filtered.artifacts.map(\.label)) == ["one", "two"])
        }
    }

    /// The parameter is added to a live endpoint, so omitting it must behave
    /// exactly as it did before.
    @Test("Omitting the session filter returns every artifact")
    func unfilteredIsUnchanged() async throws {
        try await withTestFluent(label: "test.hermes.artifacts.unfiltered") { fluent in
            await registerMigrations(on: fluent)
            try await fluent.migrate()
            let tenantID = try await Self.seedTenant(on: fluent)
            let service = Self.makeService(fluent: fluent)
            let base = Date(timeIntervalSince1970: 1_700_000_000)

            try await Self.seedArtifact(on: fluent, tenantID: tenantID, sessionID: "sess-a", label: "one", occurredAt: base)
            try await Self.seedArtifact(on: fluent, tenantID: tenantID, sessionID: "sess-b", label: "other", occurredAt: base.addingTimeInterval(1))

            let all = try await service.artifacts(
                tenantID: tenantID, kind: nil, query: nil, before: nil, limit: 50
            )
            #expect(all.artifacts.count == 2)
        }
    }

    /// An empty string is what a client sends when it has a conversation but
    /// no run yet. It must mean "no filter", not "match nothing" — and it
    /// must not match rows whose session id happens to be empty either.
    @Test("An empty session id is treated as no filter")
    func emptySessionIDIsIgnored() async throws {
        try await withTestFluent(label: "test.hermes.artifacts.emptyfilter") { fluent in
            await registerMigrations(on: fluent)
            try await fluent.migrate()
            let tenantID = try await Self.seedTenant(on: fluent)
            let service = Self.makeService(fluent: fluent)
            let base = Date(timeIntervalSince1970: 1_700_000_000)

            try await Self.seedArtifact(on: fluent, tenantID: tenantID, sessionID: "sess-a", label: "one", occurredAt: base)

            let result = try await service.artifacts(
                tenantID: tenantID, kind: nil, query: nil, before: nil, limit: 50, sessionID: ""
            )
            #expect(result.artifacts.count == 1)
        }
    }

    @Test("An unknown session returns empty rather than everything")
    func unknownSessionReturnsEmpty() async throws {
        try await withTestFluent(label: "test.hermes.artifacts.unknown") { fluent in
            await registerMigrations(on: fluent)
            try await fluent.migrate()
            let tenantID = try await Self.seedTenant(on: fluent)
            let service = Self.makeService(fluent: fluent)

            try await Self.seedArtifact(
                on: fluent, tenantID: tenantID, sessionID: "sess-a", label: "one",
                occurredAt: Date(timeIntervalSince1970: 1_700_000_000)
            )

            let none = try await service.artifacts(
                tenantID: tenantID, kind: nil, query: nil, before: nil, limit: 50, sessionID: "sess-nope"
            )
            #expect(none.artifacts.isEmpty)
        }
    }

    /// The session filter must compose with the kind filter rather than
    /// replace it.
    @Test("Session and kind filters compose")
    func sessionAndKindCompose() async throws {
        try await withTestFluent(label: "test.hermes.artifacts.compose") { fluent in
            await registerMigrations(on: fluent)
            try await fluent.migrate()
            let tenantID = try await Self.seedTenant(on: fluent)
            let service = Self.makeService(fluent: fluent)
            let base = Date(timeIntervalSince1970: 1_700_000_000)

            try await Self.seedArtifact(on: fluent, tenantID: tenantID, sessionID: "sess-a", label: "link-one", occurredAt: base)

            let image = HermesArtifactExtractor.Record(
                kind: .image, value: "/tmp/a.png", href: "/tmp/a.png", label: "img",
                sessionID: "sess-a", sessionTitle: "session sess-a",
                occurredAt: base.addingTimeInterval(1), contentHash: UUID().uuidString
            )
            try await HermesArtifact(tenantID: tenantID, record: image).save(on: fluent.db())

            let links = try await service.artifacts(
                tenantID: tenantID, kind: "link", query: nil, before: nil, limit: 50, sessionID: "sess-a"
            )
            #expect(links.artifacts.map(\.label) == ["link-one"])
        }
    }
}
