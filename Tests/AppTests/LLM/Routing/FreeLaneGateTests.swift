@testable import App
import FluentKit
import Foundation
import HummingbirdFluent
import Logging
import SQLKit
import Testing

/// The free lane's two ceilings.
///
/// Both exist because OpenRouter's free-model limits are **account-wide, not
/// per user**: a per-user grace stops one tenant starving everyone, and a
/// per-leg ceiling keeps us under the provider limit. Leg 2's ceiling is also a
/// real spend cap — NVIDIA bills at list price once its signup credits are gone.
///
/// The load-bearing test here is `concurrentClaimsNeverExceedTheCeiling`. It is
/// the reason the gate uses `UPDATE … WHERE spent + 1 <= limit RETURNING` rather
/// than a read-then-write: under the latter, two requests can both observe the
/// last unit as free and both take it.
@Suite(.serialized, .tags(.integration), .integrationDatabase, .disabled(if: IntegrationTestEnv.skipIntegration))
struct FreeLaneGateTests {
    private static func gate(
        fluent: Fluent,
        perUser: Int64 = 20,
        openRouter: Int64 = 45,
        nvidia: Int64 = 900
    ) -> FreeLaneGate {
        FreeLaneGate(
            fluent: fluent,
            limits: FreeLaneGate.Limits(
                perUserDaily: perUser,
                perLegDaily: [.openRouterFree: openRouter, .nvidiaDirect: nvidia]
            ),
            logger: Logger(label: "test.freelane.gate")
        )
    }

    private static let bothLegs: [FreeLaneCatalog.Leg] = [.openRouterFree, .nvidiaDirect]

    /// The per-leg buckets are **platform-wide by design** — that is the whole
    /// point, since OpenRouter's free limits are account-wide. So unlike the
    /// per-tenant grace, they are not isolated by using a fresh tenant UUID, and
    /// they persist for the whole UTC day. Tests that assert on a leg ceiling
    /// must therefore clear them first, or they inherit whatever earlier tests
    /// in the suite already spent.
    private static func resetLegBuckets(_ fluent: Fluent) async throws {
        guard let sql = fluent.db() as? any SQLDatabase else { return }
        try await sql.raw("DELETE FROM workflow_spend_buckets WHERE scope_key LIKE 'freelane:leg:%'").run()
    }

    @Test
    func `per-user daily grace exhausts after the configured number of requests`() async throws {
        try await withTestFluent(label: "lv.test.freelane.grace") { fluent in
            await registerMigrations(on: fluent)
            try await fluent.migrate()
            try await Self.resetLegBuckets(fluent)

            let gate = Self.gate(fluent: fluent, perUser: 3)
            let tenant = UUID()
            for _ in 0 ..< 3 {
                #expect(await gate.claim(tenantID: tenant, legs: Self.bothLegs) == .granted(.openRouterFree))
            }
            let outcome = await gate.claim(tenantID: tenant, legs: Self.bothLegs)
            guard case let .exhausted(retryAfter) = outcome else {
                Issue.record("expected exhaustion after the grace was spent, got \(outcome)")
                return
            }
            // Buckets roll at UTC midnight, which is what Retry-After promises.
            #expect(retryAfter > 0 && retryAfter <= 86_400)
        }
    }

    @Test
    func `a full leg falls over to the next leg rather than failing`() async throws {
        try await withTestFluent(label: "lv.test.freelane.failover") { fluent in
            await registerMigrations(on: fluent)
            try await fluent.migrate()
            try await Self.resetLegBuckets(fluent)

            let gate = Self.gate(fluent: fluent, perUser: 10, openRouter: 1)
            let tenant = UUID()
            #expect(await gate.claim(tenantID: tenant, legs: Self.bothLegs) == .granted(.openRouterFree))
            // Leg 1's platform ceiling is spent; leg 2 takes over.
            #expect(await gate.claim(tenantID: tenant, legs: Self.bothLegs) == .granted(.nvidiaDirect))
        }
    }

    @Test
    func `both legs full is exhaustion`() async throws {
        try await withTestFluent(label: "lv.test.freelane.bothfull") { fluent in
            await registerMigrations(on: fluent)
            try await fluent.migrate()
            try await Self.resetLegBuckets(fluent)

            let gate = Self.gate(fluent: fluent, perUser: 10, openRouter: 1, nvidia: 1)
            let tenant = UUID()
            _ = await gate.claim(tenantID: tenant, legs: Self.bothLegs)
            _ = await gate.claim(tenantID: tenant, legs: Self.bothLegs)
            let outcome = await gate.claim(tenantID: tenant, legs: Self.bothLegs)
            guard case .exhausted = outcome else {
                Issue.record("expected exhaustion with both legs full, got \(outcome)")
                return
            }
        }
    }

    /// The per-leg ceilings are shared, but the grace must not be.
    @Test
    func `tenants do not share the per-user grace`() async throws {
        try await withTestFluent(label: "lv.test.freelane.isolation") { fluent in
            await registerMigrations(on: fluent)
            try await fluent.migrate()
            try await Self.resetLegBuckets(fluent)

            let gate = Self.gate(fluent: fluent, perUser: 1)
            let first = UUID()
            let second = UUID()
            #expect(await gate.claim(tenantID: first, legs: Self.bothLegs) == .granted(.openRouterFree))
            guard case .exhausted = await gate.claim(tenantID: first, legs: Self.bothLegs) else {
                Issue.record("first tenant should be out of grace")
                return
            }
            // Second tenant is untouched by the first's spend.
            #expect(await gate.claim(tenantID: second, legs: Self.bothLegs) == .granted(.openRouterFree))
        }
    }

    /// The whole reason for the conditional-UPDATE idiom. 50 concurrent claims
    /// against a grace of 10 must grant exactly 10 — no more, no fewer.
    @Test
    func `concurrent claims never exceed the ceiling`() async throws {
        try await withTestFluent(label: "lv.test.freelane.race") { fluent in
            await registerMigrations(on: fluent)
            try await fluent.migrate()
            try await Self.resetLegBuckets(fluent)

            let gate = Self.gate(fluent: fluent, perUser: 10, openRouter: 1000)
            let tenant = UUID()

            let granted = await withTaskGroup(of: Bool.self) { group in
                for _ in 0 ..< 50 {
                    group.addTask {
                        if case .granted = await gate.claim(tenantID: tenant, legs: Self.bothLegs) {
                            return true
                        }
                        return false
                    }
                }
                var total = 0
                for await didGrant in group where didGrant { total += 1 }
                return total
            }
            #expect(granted == 10, "expected exactly the ceiling to be granted, got \(granted)")
        }
    }

    @Test
    func `remaining reflects what has been spent`() async throws {
        try await withTestFluent(label: "lv.test.freelane.remaining") { fluent in
            await registerMigrations(on: fluent)
            try await fluent.migrate()
            try await Self.resetLegBuckets(fluent)

            let gate = Self.gate(fluent: fluent, perUser: 5)
            let tenant = UUID()
            #expect(await gate.remainingToday(tenantID: tenant) == 5)
            _ = await gate.claim(tenantID: tenant, legs: Self.bothLegs)
            _ = await gate.claim(tenantID: tenant, legs: Self.bothLegs)
            #expect(await gate.remainingToday(tenantID: tenant) == 3)
        }
    }

    /// A zero ceiling means "this leg is unavailable", not "grant anyway".
    @Test
    func `a zero limit never grants`() async throws {
        try await withTestFluent(label: "lv.test.freelane.zero") { fluent in
            await registerMigrations(on: fluent)
            try await fluent.migrate()
            try await Self.resetLegBuckets(fluent)

            let gate = Self.gate(fluent: fluent, perUser: 0)
            guard case .exhausted = await gate.claim(tenantID: UUID(), legs: Self.bothLegs) else {
                Issue.record("a zero per-user limit must not grant")
                return
            }
        }
    }
}
