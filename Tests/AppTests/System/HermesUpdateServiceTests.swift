@testable import App
import FluentKit
import Foundation
import HummingbirdFluent
import Logging
import LuminaVaultShared
import SQLKit
import Testing

/// HER-330 — `HermesUpdateService` step engine, blue-green cutover, and
/// failure/rollback paths. Docker is stubbed via `StubDockerExec`; the
/// central health probe is a controllable flag. Requires
/// `docker compose up -d postgres` (the service persists job rows).
@Suite(.serialized)
struct HermesUpdateServiceTests {
    /// Controllable health probe backing.
    private actor HealthFlag {
        var value: Bool
        init(_ v: Bool) { value = v }
        func set(_ v: Bool) { value = v }
    }

    private static func truncate(_ fluent: Fluent) async throws {
        guard let sql = fluent.db() as? any SQLDatabase else { return }
        try await sql.raw("DELETE FROM hermes_update_jobs").run()
    }

    private static func makeCentral(
        docker: any DockerExec,
        healthy: HealthFlag,
    ) -> CentralHermesManager {
        CentralHermesManager(
            docker: docker,
            config: CentralHermesManager.Config(
                containerName: "luminavault-hermes",
                tempContainerName: "luminavault-hermes-next",
                registryImage: "ghcr.io/luminavault/luminavault-hermes",
                defaultChannelTag: "latest",
                network: "lvtest",
                volumePath: "/tmp/lvtest/hermes",
                port: 8642,
                tempPort: 8643,
                apiServerKey: "test-key",
                mnemosyneDataDir: "/opt/data/mnemosyne",
            ),
            healthProbe: { _, _ in await healthy.value },
            logger: Logger(label: "test.her330"),
        )
    }

    private static func awaitTerminal(
        _ service: HermesUpdateService,
        _ jobID: UUID,
        timeout: Duration = .seconds(15),
    ) async throws -> HermesUpdateJobStatus {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if let snap = try await service.job(id: jobID), snap.state != .running {
                return snap
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        Issue.record("job \(jobID) did not reach a terminal state within \(timeout)")
        return try await service.job(id: jobID)!
    }

    @Test
    func `happy path runs full pipeline and promotes new image`() async throws {
        try await withTestFluent(label: "lv.test.her330.happy") { fluent in
            await registerMigrations(on: fluent)
            try await fluent.migrate()
            try await Self.truncate(fluent)

            let docker = StubDockerExec()
            let healthy = HealthFlag(true)
            let service = HermesUpdateService(
                fluent: fluent,
                central: Self.makeCentral(docker: docker, healthy: healthy),
                containerManager: nil,
                healthTimeoutSeconds: 5,
                logger: Logger(label: "test.her330"),
            )

            let started = try await service.startUpdate(targetTag: "v2")
            #expect(started.state == .running)
            #expect(started.toVersion == "ghcr.io/luminavault/luminavault-hermes:v2")

            let final = try await Self.awaitTerminal(service, started.jobID)
            #expect(final.state == .succeeded)
            // Tenants disabled → reprovision skipped; everything else succeeded.
            for step in final.steps where step.id != .reprovisionTenants {
                #expect(step.state == .succeeded, "step \(step.id) should succeed, was \(step.state)")
            }

            // The new image was launched on the temp name, then on the canonical
            // name during cutover.
            let runs = await docker.invocations.filter { $0.kind == "run" && $0.args.first == "run" }
            let names = runs.compactMap { inv -> String? in
                guard let i = inv.args.firstIndex(of: "--name"), inv.args.indices.contains(i + 1) else { return nil }
                return inv.args[i + 1]
            }
            #expect(names.contains("luminavault-hermes-next"))
            #expect(names.contains("luminavault-hermes"))
        }
    }

    @Test
    func `unhealthy new version keeps current and reports rolled back`() async throws {
        try await withTestFluent(label: "lv.test.her330.unhealthy") { fluent in
            await registerMigrations(on: fluent)
            try await fluent.migrate()
            try await Self.truncate(fluent)

            let docker = StubDockerExec()
            let healthy = HealthFlag(false) // green container never becomes healthy
            let service = HermesUpdateService(
                fluent: fluent,
                central: Self.makeCentral(docker: docker, healthy: healthy),
                containerManager: nil,
                healthTimeoutSeconds: 1,
                logger: Logger(label: "test.her330"),
            )

            let started = try await service.startUpdate(targetTag: "broken")
            let final = try await Self.awaitTerminal(service, started.jobID)

            #expect(final.state == .rolledBack)
            let health = final.steps.first { $0.id == .healthCheckCentral }
            #expect(health?.state == .failed)

            // The temp container was removed and the canonical container was
            // NEVER re-run (old version kept serving). After runTemp + its
            // pre-run `rm -f temp`, the only canonical `rm` is none.
            let runArgs = await docker.invocations.filter { $0.kind == "run" }.map(\.args)
            let canonicalRuns = runArgs.filter { $0.first == "run" && $0.contains("luminavault-hermes") && !$0.contains("luminavault-hermes-next") }
            #expect(canonicalRuns.isEmpty, "old canonical container must not be replaced when the new version is unhealthy")
            #expect(runArgs.contains { $0.first == "rm" && $0.contains("luminavault-hermes-next") })
        }
    }

    @Test
    func `second update while one is running is rejected`() async throws {
        try await withTestFluent(label: "lv.test.her330.singleflight") { fluent in
            await registerMigrations(on: fluent)
            try await fluent.migrate()
            try await Self.truncate(fluent)

            // Seed a running job directly so the guard sees an in-flight update.
            let running = HermesUpdateJob(
                id: UUID(),
                state: .running,
                steps: [HermesUpdateStep(id: .pullImage, state: .running)],
                fromVersion: nil,
                toVersion: "ghcr.io/luminavault/luminavault-hermes:latest",
            )
            try await running.create(on: fluent.db())

            let docker = StubDockerExec()
            let service = HermesUpdateService(
                fluent: fluent,
                central: Self.makeCentral(docker: docker, healthy: HealthFlag(true)),
                containerManager: nil,
                logger: Logger(label: "test.her330"),
            )

            await #expect(throws: HermesUpdateError.alreadyRunning) {
                _ = try await service.startUpdate(targetTag: nil)
            }
        }
    }
}
