@testable import App
import FluentKit
import FluentPostgresDriver
import Foundation
import HummingbirdFluent
import Logging
import SQLKit
import Testing

/// HER-193 DB-touching tests for `SkillRunCapGuard`. Run with
/// `docker compose up -d postgres`.
@Suite(.serialized)
struct SkillRunCapGuardTests {
    fileprivate struct Harness {
        let fluent: Fluent
        let user: User
    }

    private static func withHarness<T: Sendable>(
        _ body: @Sendable (Harness) async throws -> T,
    ) async throws -> T {
        let logger = Logger(label: "test.skill-cap-guard")
        let fluent = Fluent(logger: logger)
        fluent.databases.use(
            .postgres(configuration: TestPostgres.configuration()),
            as: .psql,
        )
        let username = "scg-\(UUID().uuidString.prefix(8).lowercased())"
        let user = User(email: "\(username)@test.luminavault", username: username, passwordHash: "x")
        try await user.save(on: fluent.db())
        do {
            let result = try await body(Harness(fluent: fluent, user: user))
            try await fluent.shutdown()
            return result
        } catch {
            try? await fluent.shutdown()
            throw error
        }
    }

    private static func makeManifest(
        cap: SkillManifest.DailyRunCap?,
    ) -> SkillManifest {
        SkillManifest(
            source: .builtin,
            name: "pattern-detector",
            description: "high-capability test skill",
            allowedTools: [],
            capability: .high,
            schedule: nil,
            onEvent: [],
            outputs: [],
            dailyRunCap: cap,
            body: "",
        )
    }

    @Test
    func `ultimate tier with cap zero short circuits without DB hit`() async throws {
        try await Self.withHarness { h in
            let guardrail = SkillRunCapGuard(fluent: h.fluent, logger: Logger(label: "t"))
            let manifest = Self.makeManifest(cap: .init(trial: 3, pro: 3, ultimate: 0))
            let decision = try await guardrail.checkAndIncrement(
                tenantID: h.user.requireID(),
                tier: "ultimate",
                manifest: manifest,
            )
            #expect(decision == .allow)
        }
    }

    @Test
    func `pro tier allows three then denies fourth with retry after`() async throws {
        try await Self.withHarness { h in
            let guardrail = SkillRunCapGuard(fluent: h.fluent, logger: Logger(label: "t"))
            let manifest = Self.makeManifest(cap: .init(trial: 3, pro: 3, ultimate: 0))
            let tenantID = try h.user.requireID()

            for _ in 0 ..< 3 {
                let decision = try await guardrail.checkAndIncrement(
                    tenantID: tenantID, tier: "pro", manifest: manifest,
                )
                #expect(decision == .allow)
            }
            let fourth = try await guardrail.checkAndIncrement(
                tenantID: tenantID, tier: "pro", manifest: manifest,
            )
            switch fourth {
            case let .deny(retryAfter):
                #expect(retryAfter > 0)
                #expect(retryAfter <= 86400 + 1)
            case .allow:
                Issue.record("4th invocation must be denied per HER-193 acceptance")
            }
        }
    }

    @Test
    func `recordFailure refunds a slot so failed runs don't burn cap`() async throws {
        try await Self.withHarness { h in
            let guardrail = SkillRunCapGuard(fluent: h.fluent, logger: Logger(label: "t"))
            let manifest = Self.makeManifest(cap: .init(trial: 3, pro: 3, ultimate: 0))
            let tenantID = try h.user.requireID()

            for _ in 0 ..< 3 {
                _ = try await guardrail.checkAndIncrement(
                    tenantID: tenantID, tier: "pro", manifest: manifest,
                )
            }
            // Simulate LLM failure on the 3rd run.
            try await guardrail.recordFailure(tenantID: tenantID, manifest: manifest)

            // After refund, one slot is available again.
            let nextDecision = try await guardrail.checkAndIncrement(
                tenantID: tenantID, tier: "pro", manifest: manifest,
            )
            #expect(nextDecision == .allow)
        }
    }

    @Test
    func `stale reset stamp rolls forward and resets counter`() async throws {
        try await Self.withHarness { h in
            let guardrail = SkillRunCapGuard(fluent: h.fluent, logger: Logger(label: "t"))
            let manifest = Self.makeManifest(cap: .init(trial: 1, pro: 1, ultimate: 0))
            let tenantID = try h.user.requireID()

            // Burn the only slot.
            _ = try await guardrail.checkAndIncrement(
                tenantID: tenantID, tier: "pro", manifest: manifest,
            )

            // Backdate the reset stamp to yesterday — simulating a
            // long-idle tenant whose midnight has passed.
            guard let sql = h.fluent.db() as? any SQLDatabase else {
                Issue.record("need SQL"); return
            }
            let yesterday = Date().addingTimeInterval(-86400)
            try await sql.raw("""
            UPDATE skills_state
                SET daily_run_reset_at = \(bind: yesterday)
            WHERE tenant_id = \(bind: tenantID)
              AND source = \(bind: manifest.source.rawValue)
              AND name = \(bind: manifest.name)
            """).run()

            // Next call should reset and allow.
            let decision = try await guardrail.checkAndIncrement(
                tenantID: tenantID, tier: "pro", manifest: manifest,
            )
            #expect(decision == .allow)
        }
    }
}
