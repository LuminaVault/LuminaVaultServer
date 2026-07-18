import FluentKit
import Foundation
import HummingbirdFluent
import Logging
import LuminaVaultShared
import SQLKit

struct WorkflowTierPolicy: Sendable, Equatable {
    let activeRunLimit: Int
    let minimumScheduleMinutes: Int
    let perRunUsdMicros: Int64
    let dailyUsdMicros: Int64
    let monthlyUsdMicros: Int64

    static func policy(for tier: UserTier) -> WorkflowTierPolicy {
        switch tier {
        case .pro:
            .init(activeRunLimit: 1, minimumScheduleMinutes: 60, perRunUsdMicros: 200_000, dailyUsdMicros: 500_000, monthlyUsdMicros: 2_000_000)
        case .ultimate:
            .init(activeRunLimit: 3, minimumScheduleMinutes: 5, perRunUsdMicros: 1_000_000, dailyUsdMicros: 2_000_000, monthlyUsdMicros: 8_000_000)
        case .trial, .lapsed, .archived:
            .init(activeRunLimit: 0, minimumScheduleMinutes: 0, perRunUsdMicros: 0, dailyUsdMicros: 0, monthlyUsdMicros: 0)
        }
    }
}

enum WorkflowSpendError: Error, Equatable {
    case activeRunLimit
    case denied(WorkflowPauseReason)
}

struct WorkflowSpendReservation: Sendable {
    let tenantID: UUID
    let runID: UUID
    let amountUsdMicros: Int64
    let day: Date
    let month: Date
}

actor WorkflowSpendService {
    private let fluent: Fluent
    private let logger: Logger
    private let globalDailyUsdMicros: Int64
    private let globalMonthlyUsdMicros: Int64
    private let managedInferenceAvailable: Bool

    init(
        fluent: Fluent,
        logger: Logger,
        globalDailyUsdMicros: Int64 = 10_000_000,
        globalMonthlyUsdMicros: Int64 = 100_000_000,
        managedInferenceAvailable: Bool
    ) {
        self.fluent = fluent
        self.logger = logger
        self.globalDailyUsdMicros = globalDailyUsdMicros
        self.globalMonthlyUsdMicros = globalMonthlyUsdMicros
        self.managedInferenceAvailable = managedInferenceAvailable
    }

    func ensureCanEnqueue(tenantID: UUID, tier: UserTier) async throws -> WorkflowTierPolicy {
        let policy = WorkflowTierPolicy.policy(for: tier)
        guard policy.activeRunLimit > 0 else { throw WorkflowSpendError.activeRunLimit }
        let active = try await activeRunCount(tenantID: tenantID)
        guard active < policy.activeRunLimit else { throw WorkflowSpendError.activeRunLimit }
        return policy
    }

    func limits(tenantID: UUID, tier: UserTier) async -> WorkflowLimitsDTO {
        let policy = WorkflowTierPolicy.policy(for: tier)
        let active = await (try? activeRunCount(tenantID: tenantID)) ?? 0
        let spent = await (try? tenantSpend(tenantID: tenantID)) ?? (0, 0)
        return WorkflowLimitsDTO(
            tier: tier,
            canAuthor: policy.activeRunLimit > 0,
            activeRuns: active,
            activeRunLimit: policy.activeRunLimit,
            minimumScheduleMinutes: policy.minimumScheduleMinutes,
            perRunLimitUsdMicros: policy.perRunUsdMicros,
            dailyLimitUsdMicros: policy.dailyUsdMicros,
            dailySpentUsdMicros: spent.0,
            monthlyLimitUsdMicros: policy.monthlyUsdMicros,
            monthlySpentUsdMicros: spent.1,
            managedInferenceAvailable: managedInferenceAvailable,
            freeFallbackActive: !managedInferenceAvailable
        )
    }

    func reserveManagedCall(tenantID: UUID, runID: UUID, tier: UserTier) async throws -> WorkflowSpendReservation {
        guard managedInferenceAvailable else { throw WorkflowSpendError.denied(.providerUnavailable) }
        let policy = WorkflowTierPolicy.policy(for: tier)
        guard policy.perRunUsdMicros > 0 else { throw WorkflowSpendError.denied(.runSpendLimit) }
        let periods = Self.periodStarts()
        let globalDailyLimit = globalDailyUsdMicros
        let globalMonthlyLimit = globalMonthlyUsdMicros
        do {
            return try await fluent.db().transaction { database in
                guard let sql = database as? any SQLDatabase else {
                    throw WorkflowSpendError.denied(.providerUnavailable)
                }
                let runRow = try await sql.raw("""
                SELECT managed_spend_usd_micros
                FROM workflow_runs
                WHERE id = \(bind: runID) AND tenant_id = \(bind: tenantID)
                FOR UPDATE
                """).first()
                guard let runRow else { throw WorkflowSpendError.denied(.runSpendLimit) }
                let spent = (try? runRow.decode(column: "managed_spend_usd_micros", as: Int64.self)) ?? 0
                let reservation = policy.perRunUsdMicros - spent
                guard reservation > 0 else { throw WorkflowSpendError.denied(.runSpendLimit) }

                try await Self.reserveBucket(
                    sql: sql, scopeKey: "tenant:\(tenantID.uuidString)", periodKind: "day",
                    periodStart: periods.day, amount: reservation, limit: policy.dailyUsdMicros,
                    reason: .dailySpendLimit
                )
                try await Self.reserveBucket(
                    sql: sql, scopeKey: "tenant:\(tenantID.uuidString)", periodKind: "month",
                    periodStart: periods.month, amount: reservation, limit: policy.monthlyUsdMicros,
                    reason: .monthlySpendLimit
                )
                try await Self.reserveBucket(
                    sql: sql, scopeKey: "global", periodKind: "day",
                    periodStart: periods.day, amount: reservation, limit: globalDailyLimit,
                    reason: .globalSpendLimit
                )
                try await Self.reserveBucket(
                    sql: sql, scopeKey: "global", periodKind: "month",
                    periodStart: periods.month, amount: reservation, limit: globalMonthlyLimit,
                    reason: .globalSpendLimit
                )
                return WorkflowSpendReservation(
                    tenantID: tenantID,
                    runID: runID,
                    amountUsdMicros: reservation,
                    day: periods.day,
                    month: periods.month
                )
            }
        } catch let error as WorkflowSpendError {
            throw error
        } catch {
            logger.error("workflow spend reservation failed", metadata: ["error": .string("\(error)")])
            throw WorkflowSpendError.denied(.providerUnavailable)
        }
    }

    func reconcile(_ reservation: WorkflowSpendReservation, actualUsdMicros: Int64) async {
        let actual = max(0, actualUsdMicros)
        do {
            try await fluent.db().transaction { database in
                guard let sql = database as? any SQLDatabase else { return }
                let tenant = "tenant:\(reservation.tenantID.uuidString)"
                try await Self.reconcileBucket(sql: sql, scopeKey: tenant, periodKind: "day", periodStart: reservation.day, reservation: reservation.amountUsdMicros, actual: actual)
                try await Self.reconcileBucket(sql: sql, scopeKey: tenant, periodKind: "month", periodStart: reservation.month, reservation: reservation.amountUsdMicros, actual: actual)
                try await Self.reconcileBucket(sql: sql, scopeKey: "global", periodKind: "day", periodStart: reservation.day, reservation: reservation.amountUsdMicros, actual: actual)
                try await Self.reconcileBucket(sql: sql, scopeKey: "global", periodKind: "month", periodStart: reservation.month, reservation: reservation.amountUsdMicros, actual: actual)
                try await sql.raw("""
                UPDATE workflow_runs
                SET managed_spend_usd_micros = managed_spend_usd_micros + \(bind: actual), updated_at = NOW()
                WHERE id = \(bind: reservation.runID) AND tenant_id = \(bind: reservation.tenantID)
                """).run()
            }
            WorkflowMetrics.managedSpendUsdMicros.record(actual)
        } catch {
            logger.error("workflow spend reconciliation failed", metadata: [
                "run_id": .string(reservation.runID.uuidString),
                "error": .string("\(error)"),
            ])
        }
    }

    private func activeRunCount(tenantID: UUID) async throws -> Int {
        try await WorkflowRun.query(on: fluent.db(), tenantID: tenantID)
            .group(.or) { group in
                group.filter(\.$status == WorkflowRunStatus.queued.rawValue)
                group.filter(\.$status == WorkflowRunStatus.running.rawValue)
                group.filter(\.$status == WorkflowRunStatus.waitingForApproval.rawValue)
            }
            .count()
    }

    private func tenantSpend(tenantID: UUID) async throws -> (Int64, Int64) {
        guard let sql = fluent.db() as? any SQLDatabase else { return (0, 0) }
        let periods = Self.periodStarts()
        let scope = "tenant:\(tenantID.uuidString)"
        let rows = try await sql.raw("""
        SELECT period_kind, spent_usd_micros
        FROM workflow_spend_buckets
        WHERE scope_key = \(bind: scope)
          AND ((period_kind = 'day' AND period_start = \(bind: periods.day))
            OR (period_kind = 'month' AND period_start = \(bind: periods.month)))
        """).all()
        var daily: Int64 = 0
        var monthly: Int64 = 0
        for row in rows {
            let kind = try row.decode(column: "period_kind", as: String.self)
            let value = try row.decode(column: "spent_usd_micros", as: Int64.self)
            if kind == "day" {
                daily = value
            } else if kind == "month" {
                monthly = value
            }
        }
        return (daily, monthly)
    }

    private static func reserveBucket(sql: any SQLDatabase, scopeKey: String, periodKind: String, periodStart: Date, amount: Int64, limit: Int64, reason: WorkflowPauseReason) async throws {
        try await sql.raw("""
        INSERT INTO workflow_spend_buckets (scope_key, period_kind, period_start)
        VALUES (\(bind: scopeKey), \(bind: periodKind), \(bind: periodStart))
        ON CONFLICT (scope_key, period_kind, period_start) DO NOTHING
        """).run()
        let row = try await sql.raw("""
        UPDATE workflow_spend_buckets
        SET reserved_usd_micros = reserved_usd_micros + \(bind: amount), updated_at = NOW()
        WHERE scope_key = \(bind: scopeKey) AND period_kind = \(bind: periodKind)
          AND period_start = \(bind: periodStart)
          AND spent_usd_micros + reserved_usd_micros + \(bind: amount) <= \(bind: limit)
        RETURNING scope_key
        """).first()
        guard row != nil else { throw WorkflowSpendError.denied(reason) }
    }

    private static func reconcileBucket(sql: any SQLDatabase, scopeKey: String, periodKind: String, periodStart: Date, reservation: Int64, actual: Int64) async throws {
        try await sql.raw("""
        UPDATE workflow_spend_buckets
        SET reserved_usd_micros = GREATEST(0, reserved_usd_micros - \(bind: reservation)),
            spent_usd_micros = spent_usd_micros + \(bind: actual), updated_at = NOW()
        WHERE scope_key = \(bind: scopeKey) AND period_kind = \(bind: periodKind)
          AND period_start = \(bind: periodStart)
        """).run()
    }

    private static func periodStarts(now: Date = .now) -> (day: Date, month: Date) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? calendar.timeZone
        let day = calendar.startOfDay(for: now)
        let components = calendar.dateComponents([.year, .month], from: day)
        return (day, calendar.date(from: components) ?? day)
    }
}
