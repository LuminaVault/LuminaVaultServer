@testable import App
import FluentKit
import Foundation
import HummingbirdFluent
import Logging
import LuminaVaultShared
import Testing

/// Hermes Mirror task 7 — the refresh worker only touches tenants with a
/// dashboard URL, pages through them by id, isolates per-tenant failures and
/// respects the per-tenant budget.
@Suite(.serialized, .tags(.integration), .integrationDatabase, .disabled(if: IntegrationTestEnv.skipIntegration))
struct HermesMirrorRefreshWorkerTests {
    private static let logger = Logger(label: "test.hermes-mirror-worker")

    /// One fake per tenant; records which tenants the service asked for.
    private actor PerTenantTransports: HermesMirrorTransportProviding {
        private var fakes: [UUID: FakeHermesMirrorTransport] = [:]
        private(set) var requested: [UUID] = []

        func fake(for tenantID: UUID) -> FakeHermesMirrorTransport {
            if let existing = fakes[tenantID] {
                return existing
            }
            let created = FakeHermesMirrorTransport()
            fakes[tenantID] = created
            return created
        }

        nonisolated func kind(tenantID _: UUID) async -> HermesMirrorTransportKind {
            .remote
        }

        func transport(tenantID: UUID) async throws -> any HermesMirrorTransport {
            requested.append(tenantID)
            return fake(for: tenantID)
        }

        func requestedTenants() -> [UUID] {
            requested
        }
    }

    private struct FixedEmbedding: EmbeddingService {
        func embed(_: String, tenantID _: UUID) async throws -> [Float] {
            [Float](repeating: 0.01, count: 1536)
        }
    }

    private static func seedTenant(on fluent: Fluent, dashboard: Bool) async throws -> UUID {
        let id = UUID()
        let username = "w\(UUID().uuidString.prefix(6).lowercased())"
        try await User(id: id, email: "\(username)@test.luminavault", username: username, passwordHash: "stub").save(on: fluent.db())
        try await Vault(id: id, personalOwnerUserID: id, name: "Personal").save(on: fluent.db())
        if dashboard {
            let row = UserHermesConfig()
            row.tenantID = id
            row.baseURL = ""
            row.cronDashboardURL = "http://127.0.0.1:9119"
            row.cronDashboardTokenCiphertext = Data([1, 2, 3])
            row.cronDashboardTokenNonce = Data([4, 5, 6])
            try await row.save(on: fluent.db())
        }
        return id
    }

    private static func makeService(fluent: Fluent, transports: PerTenantTransports) -> HermesMirrorService {
        let vaultRoot = FileManager.default.temporaryDirectory.appendingPathComponent("lv-mirror-worker-\(UUID().uuidString)", isDirectory: true)
        let vaultPaths = VaultPathService(rootPath: vaultRoot.path)
        return HermesMirrorService(
            fluent: fluent,
            transports: transports,
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
            limits: {
                var limits = HermesMirrorService.Limits()
                limits.readPause = .zero
                return limits
            }(),
            logger: logger
        )
    }

    @Test
    func `tick syncs only tenants with a dashboard, pages by id, and isolates failures`() async throws {
        try await withTestFluent(label: "lv.test.mirror.worker") { fluent in
            await registerMigrations(on: fluent)
            try await fluent.migrate()
            let configuredA = try await Self.seedTenant(on: fluent, dashboard: true)
            let configuredB = try await Self.seedTenant(on: fluent, dashboard: true)
            let configuredC = try await Self.seedTenant(on: fluent, dashboard: true)
            let unconfigured = try await Self.seedTenant(on: fluent, dashboard: false)

            let transports = PerTenantTransports()
            await transports.fake(for: configuredA).setSkills([HermesMirrorSkill(name: "a", description: "", enabled: true, source: .custom, contentHash: nil)])
            await transports.fake(for: configuredB).fail("listSkills", with: .dashboardUnreachable("down"))
            await transports.fake(for: configuredB).fail("listJobs", with: .dashboardUnreachable("down"))
            let service = Self.makeService(fluent: fluent, transports: transports)
            let worker = HermesMirrorRefreshWorker(
                fluent: fluent,
                service: service,
                logger: Self.logger,
                pageSize: 2, // three configured tenants → two pages
                maxConcurrent: 2,
                perTenantBudget: .seconds(30),
                maxJitter: .zero
            )

            let summary = try await worker.tick()
            let requested = await Set(transports.requestedTenants())
            #expect(requested.isSuperset(of: [configuredA, configuredB, configuredC]))
            #expect(!requested.contains(unconfigured))
            #expect(summary.processed >= 3)
            #expect(summary.failed >= 1)
            #expect(summary.timedOut == 0)

            let stateA = try await service.status(tenantID: configuredA)
            #expect(stateA.lastStatus == .ok)
            #expect(stateA.skillsCount == 1)
            let stateB = try await service.status(tenantID: configuredB)
            #expect(stateB.lastStatus == .failed)
            #expect(try await service.loadState(tenantID: unconfigured) == nil)

            // Keyset pagination: the second page starts strictly after the first page's last row.
            let firstPage = try await worker.configuredTenants(after: nil)
            #expect(firstPage.count == 2)
            let secondPage = try await worker.configuredTenants(after: firstPage.last?.rowID)
            #expect(secondPage.count >= 1)
            #expect(Set(secondPage.map(\.tenantID)).isDisjoint(with: Set(firstPage.map(\.tenantID))))
        }
    }

    @Test
    func `a tenant exceeding its budget is reported as timed out without blocking the tick`() async throws {
        try await withTestFluent(label: "lv.test.mirror.worker.budget") { fluent in
            await registerMigrations(on: fluent)
            try await fluent.migrate()
            let slow = try await Self.seedTenant(on: fluent, dashboard: true)
            let transports = PerTenantTransports()
            let service = Self.makeService(fluent: fluent, transports: transports)
            let outcome = await HermesMirrorRefreshWorker.refresh(tenantID: slow, service: service, budget: .zero, logger: Self.logger)
            #expect(outcome == .timedOut)
        }
    }

    @Test
    func `a refresh collects each mirrored job's finished runs into the brain`() async throws {
        try await withTestFluent(label: "lv.test.mirror.worker.collect") { fluent in
            await registerMigrations(on: fluent)
            try await fluent.migrate()
            let tenantID = try await Self.seedTenant(on: fluent, dashboard: true)
            let transports = PerTenantTransports()
            let service = Self.makeService(fluent: fluent, transports: transports)
            let fake = await transports.fake(for: tenantID)
            await fake.setJobs([HermesMirrorJob(
                id: "digest", name: "Digest", schedule: "0 3 * * *", prompt: "p",
                paused: false, lastRunAt: nil, nextRunAt: nil, raw: .object(["id": .string("digest")])
            )])
            await fake.setRuns("digest", [HermesMirrorJobRun(
                key: "cron_digest_1", status: .ok,
                startedAt: Date(timeIntervalSince1970: 1_756_800_000),
                finishedAt: Date(timeIntervalSince1970: 1_756_800_060)
            )])
            await fake.setRunOutput("digest", "cron_digest_1", "# Nightly\n")

            // One tick: the jobs sync discovers the job, then collect files it.
            let outcome = await HermesMirrorRefreshWorker.refresh(
                tenantID: tenantID, service: service, budget: .seconds(30), logger: Self.logger
            )
            #expect(outcome == .ok)
            let runs = try await HermesJobRun.query(on: fluent.db(), tenantID: tenantID).all()
            #expect(runs.map(\.hermesRunKey) == ["cron_digest_1"])
            #expect(runs[0].vaultFileID != nil)

            // The next tick takes the high-water fast path: no second insert.
            _ = await HermesMirrorRefreshWorker.refresh(
                tenantID: tenantID, service: service, budget: .seconds(30), logger: Self.logger
            )
            #expect(try await HermesJobRun.query(on: fluent.db(), tenantID: tenantID).count() == 1)
        }
    }

    @Test
    func `jitter stays within the bound`() {
        for _ in 0 ..< 20 {
            let value = HermesMirrorRefreshWorker.jitter(upTo: .seconds(2))
            #expect(value >= .zero)
            #expect(value <= .seconds(2))
        }
        #expect(HermesMirrorRefreshWorker.jitter(upTo: .zero) == .zero)
    }
}
