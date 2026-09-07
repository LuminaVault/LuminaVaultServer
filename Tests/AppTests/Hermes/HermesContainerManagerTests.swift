@testable import App
import FluentKit
import Foundation
import HummingbirdFluent
import Logging
import SQLKit
import Testing

/// HER-240a — `HermesContainerManager` happy-path + edge cases. Requires
/// `docker compose up -d postgres` because the manager persists a row per
/// tenant. Docker is stubbed via `StubDockerExec`.
@Suite(.serialized, .tags(.integration), .integrationDatabase, .disabled(if: IntegrationTestEnv.skipIntegration))
struct HermesContainerManagerTests {
    private static let masterKeyBase64 = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

    private static func makeUser(_ id: UUID, _ slug: String) -> User {
        User(
            id: id,
            email: "\(slug)@test.luminavault",
            username: slug,
            passwordHash: "stub-hash-\(slug)"
        )
    }

    /// Each test truncates the container table first so port allocation
    /// and eviction queries see only this test's rows. `registerMigrations`
    /// shares one DB across the suite per `withTestFluent`.
    /// Wipe the tenants this suite's helpers create on each test so port
    /// allocation and eviction queries see only this test's rows.
    private static func truncate(_ fluent: Fluent) async throws {
        guard let sql = fluent.db() as? any SQLDatabase else { return }
        try await sql.raw("DELETE FROM hermes_tenant_containers").run()
        // Removing users with a slug prefix keeps unrelated rows that other
        // suites may have created in the shared test DB.
        try await sql.raw("DELETE FROM users WHERE username LIKE 'her240a-%'").run()
    }

    private static func makeManager(
        docker: any DockerExec,
        fluent: Fluent,
        portStart: Int = 9000,
        portEnd: Int = 9100,
        memoryLimit: String = "",
        cpuLimit: String = "",
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws -> HermesContainerManager {
        try HermesContainerManager(
            docker: docker,
            fluent: fluent,
            secretBox: SecretBox(masterKeyBase64: masterKeyBase64),
            config: HermesContainerManager.Config(
                image: "hermes:test",
                network: "lvtest",
                dataRootBase: "/tmp/lvtest",
                portRangeStart: portStart,
                portRangeEnd: portEnd,
                idleTTLSeconds: 60,
                memoryLimit: memoryLimit,
                cpuLimit: cpuLimit
            ),
            logger: Logger(label: "test.her240a"),
            now: now
        )
    }

    @Test
    func `ensureRunning spawns on first call and is idempotent on second`() async throws {
        try await withTestFluent(label: "lv.test.her240a.spawn") { fluent in
            await registerMigrations(on: fluent)
            try await fluent.migrate()
            try await Self.truncate(fluent)

            let tenantID = UUID()
            try await Self.makeUser(tenantID, "her240a-spawn").save(on: fluent.db())

            let docker = StubDockerExec()
            let manager = try Self.makeManager(docker: docker, fluent: fluent)

            let first = try await manager.ensureRunning(tenantID: tenantID)
            #expect(first.containerName.hasPrefix("hermes-tenant-"))
            #expect((9000 ..< 9100).contains(first.port))

            let runInvocations = await docker.invocations.filter { $0.kind == "run" && $0.args.first == "run" }
            #expect(runInvocations.count == 1, "second call must not spawn a new container")

            let second = try await manager.ensureRunning(tenantID: tenantID)
            #expect(second.containerName == first.containerName)
            #expect(second.port == first.port)
            let runInvocationsAfter = await docker.invocations.filter { $0.kind == "run" && $0.args.first == "run" }
            #expect(runInvocationsAfter.count == 1)

            // Persisted row reflects the spawn.
            let row = try await HermesTenantContainer.query(on: fluent.db())
                .filter(\.$tenantID == tenantID)
                .first()
            #expect(row?.containerName == first.containerName)
            #expect(row?.xaiConnectedAt == nil)
        }
    }

    /// Tenant containers run `--restart=unless-stopped` with no ceiling, so
    /// one tenant whose agent loops on a large context could OOM the node and
    /// take every other tenant — and the API — down with it.
    @Test
    func `configured resource limits reach docker run`() async throws {
        try await withTestFluent(label: "lv.test.her240a.limits") { fluent in
            await registerMigrations(on: fluent)
            try await fluent.migrate()
            try await Self.truncate(fluent)

            let tenantID = UUID()
            try await Self.makeUser(tenantID, "her240a-limits").save(on: fluent.db())

            let docker = StubDockerExec()
            let manager = try Self.makeManager(
                docker: docker,
                fluent: fluent,
                memoryLimit: "512m",
                cpuLimit: "1.5"
            )
            _ = try await manager.ensureRunning(tenantID: tenantID)

            let args = await docker.invocations.first { $0.args.first == "run" }?.args ?? []
            #expect(args.contains("--memory"))
            #expect(args.contains("512m"))
            #expect(args.contains("--cpus"))
            #expect(args.contains("1.5"))
            // The flags must precede the image, or docker reads them as
            // arguments to the container's own entrypoint.
            let imageIndex = args.firstIndex(of: "hermes:test") ?? 0
            #expect((args.firstIndex(of: "--memory") ?? .max) < imageIndex)
            #expect((args.firstIndex(of: "--cpus") ?? .max) < imageIndex)
        }
    }

    /// A host whose cgroup driver cannot honour a limit configures it empty,
    /// and must then get a command with no flag rather than an empty value.
    @Test
    func `unset resource limits emit no flags`() async throws {
        try await withTestFluent(label: "lv.test.her240a.nolimits") { fluent in
            await registerMigrations(on: fluent)
            try await fluent.migrate()
            try await Self.truncate(fluent)

            let tenantID = UUID()
            try await Self.makeUser(tenantID, "her240a-nolimits").save(on: fluent.db())

            let docker = StubDockerExec()
            let manager = try Self.makeManager(docker: docker, fluent: fluent)
            _ = try await manager.ensureRunning(tenantID: tenantID)

            let args = await docker.invocations.first { $0.args.first == "run" }?.args ?? []
            #expect(args.contains("--memory") == false)
            #expect(args.contains("--cpus") == false)
        }
    }

    @Test
    func `ensureRunning restarts stopped container without reallocating port`() async throws {
        try await withTestFluent(label: "lv.test.her240a.restart") { fluent in
            await registerMigrations(on: fluent)
            try await fluent.migrate()
            try await Self.truncate(fluent)

            let tenantID = UUID()
            try await Self.makeUser(tenantID, "her240a-restart").save(on: fluent.db())

            let docker = StubDockerExec()
            let manager = try Self.makeManager(docker: docker, fluent: fluent)
            let first = try await manager.ensureRunning(tenantID: tenantID)

            // Simulate the container going down.
            await docker.setRunning(first.containerName, false)
            let second = try await manager.ensureRunning(tenantID: tenantID)
            #expect(second.port == first.port)
            #expect(second.containerName == first.containerName)
            let dockerRuns = await docker.invocations.filter { $0.kind == "run" && $0.args.first == "run" }
            #expect(dockerRuns.count == 2)
        }
    }

    @Test
    func `evictIdle removes only stale containers without xai connection`() async throws {
        try await withTestFluent(label: "lv.test.her240a.evict") { fluent in
            await registerMigrations(on: fluent)
            try await fluent.migrate()
            try await Self.truncate(fluent)

            let idleTenant = UUID()
            let activeTenant = UUID()
            let connectedTenant = UUID()
            try await Self.makeUser(idleTenant, "her240a-idle").save(on: fluent.db())
            try await Self.makeUser(activeTenant, "her240a-active").save(on: fluent.db())
            try await Self.makeUser(connectedTenant, "her240a-conn").save(on: fluent.db())

            let docker = StubDockerExec()
            // Real-time clock so SQL `now()` and the manager's cutoff agree.
            let manager = try Self.makeManager(docker: docker, fluent: fluent)

            try await manager.ensureRunning(tenantID: idleTenant)
            try await manager.ensureRunning(tenantID: activeTenant)
            try await manager.ensureRunning(tenantID: connectedTenant)
            try await manager.recordXaiConnected(tenantID: connectedTenant, at: Date())

            // Push idleTenant's last_used_at past the 60s TTL.
            guard let sql = fluent.db() as? any SQLDatabase else {
                Issue.record("SQL driver required")
                return
            }
            try await sql.raw("""
            UPDATE hermes_tenant_containers
            SET last_used_at = now() - interval '120 seconds'
            WHERE tenant_id = \(bind: idleTenant)
            """).run()

            let evicted = try await manager.evictIdle()
            #expect(evicted == 1)

            let surviving = try await HermesTenantContainer.query(on: fluent.db()).all().map(\.tenantID)
            #expect(surviving.contains(activeTenant))
            #expect(surviving.contains(connectedTenant))
            #expect(!surviving.contains(idleTenant))
        }
    }

    @Test
    func `evictIdle never reaps a stale Nous-connected container`() async throws {
        try await withTestFluent(label: "lv.test.nous.evict") { fluent in
            await registerMigrations(on: fluent)
            try await fluent.migrate()
            try await Self.truncate(fluent)

            let nousTenant = UUID()
            try await Self.makeUser(nousTenant, "her240a-nous").save(on: fluent.db())

            let docker = StubDockerExec()
            let manager = try Self.makeManager(docker: docker, fluent: fluent)

            try await manager.ensureRunning(tenantID: nousTenant)
            try await manager.recordNousConnected(tenantID: nousTenant, at: Date())

            // Age the container well past the idle TTL.
            guard let sql = fluent.db() as? any SQLDatabase else {
                Issue.record("SQL driver required")
                return
            }
            try await sql.raw("""
            UPDATE hermes_tenant_containers
            SET last_used_at = now() - interval '120 seconds'
            WHERE tenant_id = \(bind: nousTenant)
            """).run()

            let evicted = try await manager.evictIdle()
            #expect(evicted == 0)

            let surviving = try await HermesTenantContainer.query(on: fluent.db()).all().map(\.tenantID)
            #expect(surviving.contains(nousTenant))
        }
    }

    @Test
    func `port range exhaustion throws`() async throws {
        try await withTestFluent(label: "lv.test.her240a.exhaust") { fluent in
            await registerMigrations(on: fluent)
            try await fluent.migrate()
            try await Self.truncate(fluent)

            let docker = StubDockerExec()
            // Range of exactly one — second tenant exhausts.
            let manager = try Self.makeManager(
                docker: docker,
                fluent: fluent,
                portStart: 9000,
                portEnd: 9001
            )

            let t1 = UUID(); let t2 = UUID()
            try await Self.makeUser(t1, "her240a-ex1").save(on: fluent.db())
            try await Self.makeUser(t2, "her240a-ex2").save(on: fluent.db())
            try await manager.ensureRunning(tenantID: t1)
            await #expect(throws: HermesContainerManager.Error.portRangeExhausted) {
                try await manager.ensureRunning(tenantID: t2)
            }
        }
    }
}
