import Foundation
import Hummingbird
import HummingbirdFluent
import Logging
import LuminaVaultShared
import SQLKit

actor ParallelExecutionStore {
    private let fluent: Fluent
    private let logger: Logger

    init(fluent: Fluent, logger: Logger) {
        self.fluent = fluent
        self.logger = logger
    }

    func begin(
        metadata: CerberusDecisionMetadata,
        strategy: ParallelStrategyDTO,
        prompt: String?,
        participantCount: Int
    ) async {
        guard let sql = fluent.db() as? any SQLDatabase else { return }
        do {
            try await sql.raw("""
            INSERT INTO router_executions
                (id, tenant_id, profile_id, rule_id, surface, task_type, strategy, status,
                 conversation_id, space_id, prompt, parallel_strategy, participant_count)
            VALUES
                (\(bind: metadata.executionID), \(bind: metadata.tenantID), \(bind: metadata.profileID),
                 \(bind: metadata.ruleID), \(bind: metadata.surface.rawValue), \(bind: metadata.taskType.rawValue),
                 'ensemble', 'running', \(bind: metadata.conversationID), \(bind: metadata.spaceID),
                 \(bind: prompt), \(bind: strategy.rawValue), \(bind: participantCount))
            ON CONFLICT (id) DO UPDATE SET
                status = 'running', parallel_strategy = EXCLUDED.parallel_strategy,
                participant_count = EXCLUDED.participant_count
            """).run()
        } catch {
            logger.error("parallel execution begin failed", metadata: ["error": .string("\(error)")])
        }
    }

    func save(output: ParallelExecutionOutput, executionID: UUID) async {
        guard let sql = fluent.db() as? any SQLDatabase else { return }
        do {
            try await sql.raw("""
            INSERT INTO router_outputs
                (id, execution_id, participant_id, role, provider, model, stage, round,
                 content, status, tokens_in, tokens_out, estimated_cost_usd_micros, latency_ms)
            VALUES
                (\(bind: output.id), \(bind: executionID), \(bind: output.participantID),
                 \(bind: output.role), \(bind: output.route.provider.rawValue), \(bind: output.route.modelID),
                 \(bind: output.stage.rawValue), \(bind: output.round), \(bind: output.content), 'ok',
                 \(bind: Int64(output.tokensIn)), \(bind: Int64(output.tokensOut)),
                 \(bind: output.estimatedCostUsdMicros), \(bind: Int64(output.latencyMs)))
            ON CONFLICT (id) DO NOTHING
            """).run()
            try await sql.raw("""
            INSERT INTO router_attempts
                (id, execution_id, ordinal, role, provider, model, outcome, tokens_in,
                 tokens_out, estimated_cost_usd_micros, latency_ms, usage_estimated)
            VALUES
                (\(bind: UUID()), \(bind: executionID),
                 (SELECT COUNT(*)::int FROM router_attempts WHERE execution_id = \(bind: executionID)),
                 \(bind: output.stage.rawValue), \(bind: output.route.provider.rawValue),
                 \(bind: output.route.modelID), 'ok', \(bind: Int64(output.tokensIn)),
                 \(bind: Int64(output.tokensOut)), \(bind: output.estimatedCostUsdMicros),
                 \(bind: Int64(output.latencyMs)), TRUE)
            """).run()
        } catch {
            logger.error("parallel output persist failed", metadata: ["error": .string("\(error)")])
        }
    }

    func finish(
        executionID: UUID,
        status: ParallelExecutionStatusDTO,
        synthesizedAnswer: String?,
        latencyMs: Int
    ) async {
        guard let sql = fluent.db() as? any SQLDatabase else { return }
        do {
            try await sql.raw("""
            UPDATE router_executions
            SET status = \(bind: status == .completed ? "ok" : status.rawValue),
                synthesized_answer = \(bind: synthesizedAnswer),
                degraded = \(bind: status == .degraded),
                tokens_in = COALESCE((SELECT SUM(tokens_in) FROM router_outputs WHERE execution_id = \(bind: executionID)), 0),
                tokens_out = COALESCE((SELECT SUM(tokens_out) FROM router_outputs WHERE execution_id = \(bind: executionID)), 0),
                estimated_cost_usd_micros = COALESCE((SELECT SUM(estimated_cost_usd_micros) FROM router_outputs WHERE execution_id = \(bind: executionID)), 0),
                latency_ms = \(bind: Int64(latencyMs))
            WHERE id = \(bind: executionID)
            """).run()
        } catch {
            logger.error("parallel execution finalize failed", metadata: ["error": .string("\(error)")])
        }
    }

    func list(tenantID: UUID) async throws -> ParallelExecutionsResponse {
        guard let sql = fluent.db() as? any SQLDatabase else { return .init(executions: []) }
        let rows = try await sql.raw("""
        SELECT id, COALESCE(parallel_strategy, 'consensus') AS parallel_strategy, status,
               COALESCE(prompt, '') AS prompt, participant_count,
               estimated_cost_usd_micros, latency_ms, occurred_at
        FROM router_executions
        WHERE tenant_id = \(bind: tenantID) AND parallel_strategy IS NOT NULL
        ORDER BY occurred_at DESC LIMIT 50
        """).all(decoding: ExecutionRow.self)
        return ParallelExecutionsResponse(executions: rows.map(Self.summary))
    }

    func detail(tenantID: UUID, id: UUID) async throws -> ParallelExecutionDetailDTO? {
        guard let sql = fluent.db() as? any SQLDatabase else { return nil }
        guard let execution = try await sql.raw("""
        SELECT id, COALESCE(parallel_strategy, 'consensus') AS parallel_strategy, status,
               COALESCE(prompt, '') AS prompt, participant_count,
               estimated_cost_usd_micros, latency_ms, occurred_at, synthesized_answer
        FROM router_executions WHERE id = \(bind: id) AND tenant_id = \(bind: tenantID)
        """).first(decoding: ExecutionDetailRow.self) else { return nil }
        let outputRows = try await sql.raw("""
        SELECT id, participant_id, role, provider, model, stage, round, content, status,
               tokens_in, tokens_out, estimated_cost_usd_micros, latency_ms
        FROM router_outputs WHERE execution_id = \(bind: id)
        ORDER BY round, occurred_at
        """).all(decoding: OutputRow.self)
        return ParallelExecutionDetailDTO(
            summary: Self.summary(execution.row),
            prompt: execution.row.prompt,
            outputs: outputRows.compactMap(Self.output),
            synthesizedAnswer: execution.synthesized_answer
        )
    }

    func delete(tenantID: UUID, id: UUID) async throws -> Bool {
        guard let sql = fluent.db() as? any SQLDatabase else { return false }
        return try await sql.raw("""
        DELETE FROM router_executions WHERE id = \(bind: id) AND tenant_id = \(bind: tenantID)
        RETURNING id
        """).first() != nil
    }

    func presets(tenantID: UUID) async throws -> SynthesisPresetsResponse {
        guard let sql = fluent.db() as? any SQLDatabase else { return .init(presets: []) }
        let rows = try await sql.raw("""
        SELECT id, name, prompt, created_at, updated_at
        FROM router_synthesis_presets WHERE tenant_id = \(bind: tenantID)
        ORDER BY updated_at DESC
        """).all(decoding: PresetRow.self)
        return SynthesisPresetsResponse(presets: rows.map(Self.preset))
    }

    func preset(tenantID: UUID, id: UUID) async throws -> SynthesisPresetDTO? {
        guard let sql = fluent.db() as? any SQLDatabase else { return nil }
        return try await sql.raw("""
        SELECT id, name, prompt, created_at, updated_at
        FROM router_synthesis_presets WHERE tenant_id = \(bind: tenantID) AND id = \(bind: id)
        """).first(decoding: PresetRow.self).map(Self.preset)
    }

    func createPreset(tenantID: UUID, request: SynthesisPresetWriteRequest) async throws -> SynthesisPresetDTO {
        guard let sql = fluent.db() as? any SQLDatabase else { throw HTTPError(.internalServerError) }
        let row = try await sql.raw("""
        INSERT INTO router_synthesis_presets (id, tenant_id, name, prompt)
        VALUES (\(bind: UUID()), \(bind: tenantID), \(bind: request.name), \(bind: request.prompt))
        RETURNING id, name, prompt, created_at, updated_at
        """).first(decoding: PresetRow.self)
        guard let row else { throw HTTPError(.internalServerError) }
        return Self.preset(row)
    }

    func updatePreset(tenantID: UUID, id: UUID, request: SynthesisPresetWriteRequest) async throws -> SynthesisPresetDTO? {
        guard let sql = fluent.db() as? any SQLDatabase else { return nil }
        return try await sql.raw("""
        UPDATE router_synthesis_presets SET name = \(bind: request.name), prompt = \(bind: request.prompt), updated_at = NOW()
        WHERE tenant_id = \(bind: tenantID) AND id = \(bind: id)
        RETURNING id, name, prompt, created_at, updated_at
        """).first(decoding: PresetRow.self).map(Self.preset)
    }

    func deletePreset(tenantID: UUID, id: UUID) async throws -> Bool {
        guard let sql = fluent.db() as? any SQLDatabase else { return false }
        return try await sql.raw("""
        DELETE FROM router_synthesis_presets WHERE tenant_id = \(bind: tenantID) AND id = \(bind: id) RETURNING id
        """).first() != nil
    }

    private static func summary(_ row: ExecutionRow) -> ParallelExecutionSummaryDTO {
        ParallelExecutionSummaryDTO(
            id: row.id,
            strategy: ParallelStrategyDTO(rawValue: row.parallel_strategy) ?? .consensus,
            status: status(row.status),
            promptPreview: String(row.prompt.prefix(160)),
            participantCount: row.participant_count,
            estimatedCostUsdMicros: row.estimated_cost_usd_micros,
            latencyMs: Int(row.latency_ms),
            createdAt: row.occurred_at
        )
    }

    private static func output(_ row: OutputRow) -> ParallelOutputDTO? {
        guard let provider = ProviderID(rawValue: row.provider),
              let stage = ParallelOutputStageDTO(rawValue: row.stage)
        else { return nil }
        return ParallelOutputDTO(
            id: row.id,
            participantID: row.participant_id,
            role: row.role,
            route: .init(provider: provider, model: row.model),
            stage: stage,
            round: row.round,
            content: row.content,
            status: row.status,
            tokensIn: Int(row.tokens_in),
            tokensOut: Int(row.tokens_out),
            estimatedCostUsdMicros: row.estimated_cost_usd_micros,
            latencyMs: Int(row.latency_ms)
        )
    }

    private static func preset(_ row: PresetRow) -> SynthesisPresetDTO {
        .init(id: row.id, name: row.name, prompt: row.prompt, createdAt: row.created_at, updatedAt: row.updated_at)
    }

    private static func status(_ raw: String) -> ParallelExecutionStatusDTO {
        if raw == "ok" {
            return .completed
        }
        return ParallelExecutionStatusDTO(rawValue: raw) ?? .failed
    }
}

private struct ExecutionRow: Decodable {
    let id: UUID
    let parallel_strategy: String
    let status: String
    let prompt: String
    let participant_count: Int
    let estimated_cost_usd_micros: Int64
    let latency_ms: Int64
    let occurred_at: Date
}

private struct ExecutionDetailRow: Decodable {
    let id: UUID
    let parallel_strategy: String
    let status: String
    let prompt: String
    let participant_count: Int
    let estimated_cost_usd_micros: Int64
    let latency_ms: Int64
    let occurred_at: Date
    let synthesized_answer: String?

    var row: ExecutionRow {
        .init(
            id: id,
            parallel_strategy: parallel_strategy,
            status: status,
            prompt: prompt,
            participant_count: participant_count,
            estimated_cost_usd_micros: estimated_cost_usd_micros,
            latency_ms: latency_ms,
            occurred_at: occurred_at
        )
    }
}

private struct OutputRow: Decodable {
    let id: UUID
    let participant_id: UUID?
    let role: String
    let provider: String
    let model: String
    let stage: String
    let round: Int
    let content: String
    let status: String
    let tokens_in: Int64
    let tokens_out: Int64
    let estimated_cost_usd_micros: Int64
    let latency_ms: Int64
}

private struct PresetRow: Decodable {
    let id: UUID
    let name: String
    let prompt: String
    let created_at: Date
    let updated_at: Date
}
