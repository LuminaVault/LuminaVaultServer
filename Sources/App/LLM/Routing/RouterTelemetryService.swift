import FluentKit
import Foundation
import HummingbirdFluent
import Logging
import LuminaVaultShared
import SQLKit

enum RouterBudgetState: Equatable {
    case allowed
    case softLimit
    case denied
}

struct RouterExecutionResult: Sendable {
    let provider: ProviderKind?
    let model: String?
    let status: String
    let tokensIn: Int
    let tokensOut: Int
    let estimatedCostUsdMicros: Int64
    let latencyMs: Int
    let usageEstimated: Bool
    let fallbackCount: Int
}

/// Prompt-free router telemetry and the atomic monthly budget reservation.
/// The database update is conditional, so concurrent requests cannot both
/// reserve the same remaining hard-budget balance.
actor RouterTelemetryService {
    private let fluent: Fluent
    private let logger: Logger

    init(fluent: Fluent, logger: Logger) {
        self.fluent = fluent
        self.logger = logger
    }

    func reserve(
        tenantID: UUID,
        predictedUsdMicros: Int64,
        policy: RouterBudgetPolicyDTO
    ) async -> RouterBudgetState {
        guard predictedUsdMicros > 0 else { return .allowed }
        guard let sql = fluent.db() as? any SQLDatabase else { return .denied }
        do {
            try await sql.raw("""
            INSERT INTO router_monthly_usage (tenant_id, month)
            VALUES (\(bind: tenantID), date_trunc('month', CURRENT_DATE)::date)
            ON CONFLICT (tenant_id, month) DO NOTHING
            """).run()

            if let hard = policy.hardLimitUsdMicros, hard > 0 {
                let reserved = try await sql.raw("""
                UPDATE router_monthly_usage
                SET reserved_usd_micros = reserved_usd_micros + \(bind: predictedUsdMicros),
                    updated_at = NOW()
                WHERE tenant_id = \(bind: tenantID)
                  AND month = date_trunc('month', CURRENT_DATE)::date
                  AND managed_usd_micros + byok_usd_micros + reserved_usd_micros + \(bind: predictedUsdMicros) <= \(bind: hard)
                RETURNING managed_usd_micros + byok_usd_micros AS spent
                """).first()
                guard let reserved else { return .denied }
                let spent = (try? reserved.decode(column: "spent", as: Int64.self)) ?? 0
                if let soft = policy.softLimitUsdMicros, spent >= soft { return .softLimit }
                return .allowed
            }

            let row = try await sql.raw("""
            SELECT managed_usd_micros + byok_usd_micros AS spent
            FROM router_monthly_usage
            WHERE tenant_id = \(bind: tenantID)
              AND month = date_trunc('month', CURRENT_DATE)::date
            """).first()
            let spent = (try? row?.decode(column: "spent", as: Int64.self)) ?? 0
            if let soft = policy.softLimitUsdMicros, spent >= soft { return .softLimit }
            return .allowed
        } catch {
            logger.error("cerberus budget reservation failed", metadata: ["error": .string("\(error)")])
            return .denied
        }
    }

    func release(tenantID: UUID, reservedUsdMicros: Int64) async {
        guard reservedUsdMicros > 0, let sql = fluent.db() as? any SQLDatabase else { return }
        do {
            try await sql.raw("""
            UPDATE router_monthly_usage
            SET reserved_usd_micros = GREATEST(0, reserved_usd_micros - \(bind: reservedUsdMicros)),
                updated_at = NOW()
            WHERE tenant_id = \(bind: tenantID)
              AND month = date_trunc('month', CURRENT_DATE)::date
            """).run()
        } catch {
            logger.error("cerberus budget release failed", metadata: ["error": .string("\(error)")])
        }
    }

    func complete(metadata: CerberusDecisionMetadata, result: RouterExecutionResult) async {
        guard let sql = fluent.db() as? any SQLDatabase else { return }
        let provider = result.provider?.rawValue
        let modeColumn = metadata.mode == .managed ? "managed_usd_micros" : "byok_usd_micros"
        do {
            try await sql.raw("""
            INSERT INTO router_executions
                (id, tenant_id, profile_id, rule_id, surface, task_type, strategy, status,
                 selected_provider, selected_model, tokens_in, tokens_out,
                 estimated_cost_usd_micros, latency_ms, usage_estimated, fallback_count)
            VALUES
                (\(bind: metadata.executionID), \(bind: metadata.tenantID), \(bind: metadata.profileID),
                 \(bind: metadata.ruleID), \(bind: metadata.surface.rawValue), \(bind: metadata.taskType.rawValue),
                 \(bind: metadata.strategy.rawValue), \(bind: result.status), \(bind: provider),
                 \(bind: result.model), \(bind: Int64(result.tokensIn)), \(bind: Int64(result.tokensOut)),
                 \(bind: result.estimatedCostUsdMicros), \(bind: Int64(result.latencyMs)),
                 \(bind: result.usageEstimated), \(bind: result.fallbackCount))
            ON CONFLICT (id) DO UPDATE SET
                status = EXCLUDED.status,
                selected_provider = EXCLUDED.selected_provider,
                selected_model = EXCLUDED.selected_model,
                tokens_in = EXCLUDED.tokens_in,
                tokens_out = EXCLUDED.tokens_out,
                estimated_cost_usd_micros = EXCLUDED.estimated_cost_usd_micros,
                latency_ms = EXCLUDED.latency_ms,
                usage_estimated = EXCLUDED.usage_estimated,
                fallback_count = EXCLUDED.fallback_count
            """).run()

            try await sql.raw("""
            INSERT INTO router_monthly_usage
                (tenant_id, month, \(unsafeRaw: modeColumn), requests, successful_requests,
                 fallback_count, tokens_in, tokens_out, latency_ms_total)
            VALUES
                (\(bind: metadata.tenantID), date_trunc('month', CURRENT_DATE)::date,
                 \(bind: result.estimatedCostUsdMicros), 1, \(bind: result.status == "ok" ? 1 : 0),
                 \(bind: Int64(result.fallbackCount)), \(bind: Int64(result.tokensIn)),
                 \(bind: Int64(result.tokensOut)), \(bind: Int64(result.latencyMs)))
            ON CONFLICT (tenant_id, month) DO UPDATE SET
                \(unsafeRaw: modeColumn) = router_monthly_usage.\(unsafeRaw: modeColumn) + EXCLUDED.\(unsafeRaw: modeColumn),
                reserved_usd_micros = GREATEST(0, router_monthly_usage.reserved_usd_micros - \(bind: metadata.budgetReservationUsdMicros)),
                requests = router_monthly_usage.requests + 1,
                successful_requests = router_monthly_usage.successful_requests + EXCLUDED.successful_requests,
                fallback_count = router_monthly_usage.fallback_count + EXCLUDED.fallback_count,
                tokens_in = router_monthly_usage.tokens_in + EXCLUDED.tokens_in,
                tokens_out = router_monthly_usage.tokens_out + EXCLUDED.tokens_out,
                latency_ms_total = router_monthly_usage.latency_ms_total + EXCLUDED.latency_ms_total,
                updated_at = NOW()
            """).run()
        } catch {
            logger.error("cerberus execution telemetry failed", metadata: ["error": .string("\(error)")])
            await release(tenantID: metadata.tenantID, reservedUsdMicros: metadata.budgetReservationUsdMicros)
        }
    }
}
