@testable import App
import FluentKit
import Foundation
import HummingbirdFluent
import Logging
import LuminaVaultShared
import Testing

/// The trial token cap, exercised against a real database.
///
/// `checkBudget` sums today's usage with `COALESCE(SUM(mtok_in + mtok_out), 0)`.
/// Both columns are `BIGINT`, and Postgres widens `SUM(bigint)` to `numeric`,
/// which does not decode into the `Int64` the row type asked for. So every
/// budget check threw a `PostgresDecodingError`, every one landed in the
/// fail-open `catch`, and the trial cap and the per-skill cap were never
/// enforced — a trial account could spend without limit. It went unnoticed
/// because the failure is logged and swallowed, and because nothing tested the
/// check against Postgres: any in-memory stand-in returns whatever integer it
/// is handed.
///
/// These cases are the ones that would have shown it: a tenant under the cap is
/// allowed, over the soft cap is degraded, over the hard cap is denied.
@Suite(.serialized, .tags(.integration), .integrationDatabase, .disabled(if: IntegrationTestEnv.skipIntegration))
struct UsageMeterBudgetTests {
    /// One million tokens a day, so the soft cap is 800_000.
    private static func service(on fluent: Fluent) -> UsageMeterService {
        UsageMeterService(
            fluent: fluent,
            freeMtokDaily: 1.0,
            perSkillMtokDaily: 0.5,
            degradeModel: "cheap/model",
            logger: Logger(label: "lv.test.usage-meter")
        )
    }

    private static func makeTenant(on fluent: Fluent) async throws -> UUID {
        let id = UUID()
        let user = User(
            id: id,
            email: "meter-\(UUID().uuidString.prefix(8).lowercased())@test.luminavault",
            username: "meter-\(UUID().uuidString.prefix(6).lowercased())",
            passwordHash: "stub"
        )
        try await saveTenant(user, on: fluent.db())
        return id
    }

    @Test
    func `a trial tenant under the cap is allowed`() async throws {
        try await withTestFluent(label: "lv.test.usage-meter.under") { fluent in
            await registerMigrations(on: fluent)
            try await fluent.migrate()
            let tenant = try await Self.makeTenant(on: fluent)
            let meter = Self.service(on: fluent)

            await meter.record(tenantID: tenant, model: "a", tokensIn: 1000, tokensOut: 1000)

            #expect(await meter.checkBudget(tenantID: tenant, tier: .trial) == .allow)
        }
    }

    @Test
    func `a trial tenant over the soft cap is degraded`() async throws {
        try await withTestFluent(label: "lv.test.usage-meter.soft") { fluent in
            await registerMigrations(on: fluent)
            try await fluent.migrate()
            let tenant = try await Self.makeTenant(on: fluent)
            let meter = Self.service(on: fluent)

            await meter.record(tenantID: tenant, model: "a", tokensIn: 500_000, tokensOut: 350_000)

            #expect(await meter.checkBudget(tenantID: tenant, tier: .trial) == .degrade(model: "cheap/model"))
        }
    }

    @Test
    func `a trial tenant over the hard cap is denied`() async throws {
        try await withTestFluent(label: "lv.test.usage-meter.hard") { fluent in
            await registerMigrations(on: fluent)
            try await fluent.migrate()
            let tenant = try await Self.makeTenant(on: fluent)
            let meter = Self.service(on: fluent)

            // Spread across two models: the cap is per tenant, not per model.
            await meter.record(tenantID: tenant, model: "a", tokensIn: 600_000, tokensOut: 0)
            await meter.record(tenantID: tenant, model: "b", tokensIn: 0, tokensOut: 600_000)

            guard case .deny = await meter.checkBudget(tenantID: tenant, tier: .trial) else {
                Issue.record("1.2M tokens against a 1M cap was not denied")
                return
            }
        }
    }

    @Test
    func `a skill over its own cap is denied`() async throws {
        try await withTestFluent(label: "lv.test.usage-meter.skill") { fluent in
            await registerMigrations(on: fluent)
            try await fluent.migrate()
            let tenant = try await Self.makeTenant(on: fluent)
            let meter = Self.service(on: fluent)

            await meter.record(tenantID: tenant, model: "skill:digest/x", tokensIn: 400_000, tokensOut: 200_000)

            guard case .deny = await meter.checkSkillBudget(tenantID: tenant, skillName: "digest") else {
                Issue.record("600k tokens against a 500k per-skill cap was not denied")
                return
            }
        }
    }
}
