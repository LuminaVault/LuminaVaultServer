import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import LuminaVaultShared
import SQLKit

struct MemoryContributionInput: Sendable {
    let operation: MemoryContributionOperationDTO
    let actor: MemoryActorKindDTO
    let source: MemorySourceKindDTO
    let provider: String?
    let model: String?
    let sourceReference: String?

    static func user(
        _ operation: MemoryContributionOperationDTO,
        source: MemorySourceKindDTO = .manual,
        reference: String? = nil
    ) -> Self {
        .init(
            operation: operation,
            actor: .user,
            source: source,
            provider: nil,
            model: nil,
            sourceReference: reference
        )
    }

    static func model(
        _ operation: MemoryContributionOperationDTO,
        source: MemorySourceKindDTO,
        provider: String?,
        model: String?,
        reference: String? = nil
    ) -> Self {
        .init(
            operation: operation,
            actor: .model,
            source: source,
            provider: provider,
            model: model,
            sourceReference: reference
        )
    }

    static let legacy = Self(
        operation: .create,
        actor: .system,
        source: .legacy,
        provider: nil,
        model: nil,
        sourceReference: nil
    )
}

struct MemoryProvenanceRepository: Sendable {
    let fluent: Fluent

    func record(tenantID: UUID, memoryID: UUID, input: MemoryContributionInput) async throws {
        guard let sql = fluent.db() as? any SQLDatabase else {
            throw HTTPError(.internalServerError, message: "SQL driver required for memory provenance")
        }
        try await sql.raw("""
        INSERT INTO memory_contributions
            (id, tenant_id, memory_id, operation, actor_kind, source_kind,
             provider, model, source_reference, created_at)
        VALUES (
            \(bind: UUID()), \(bind: tenantID), \(bind: memoryID),
            \(bind: input.operation.rawValue), \(bind: input.actor.rawValue),
            \(bind: input.source.rawValue), \(bind: input.provider),
            \(bind: input.model), \(bind: input.sourceReference), NOW()
        )
        """).run()
    }

    func timeline(tenantID: UUID, memoryID: UUID) async throws -> MemoryProvenanceResponse? {
        guard let sql = fluent.db() as? any SQLDatabase else {
            throw HTTPError(.internalServerError, message: "SQL driver required for memory provenance")
        }
        let exists = try await Memory.query(on: fluent.db(), tenantID: tenantID)
            .filter(\.$id == memoryID)
            .first() != nil
        guard exists else { return nil }
        let rows = try await sql.raw("""
        SELECT id, operation, actor_kind, source_kind, provider, model,
               source_reference, created_at
        FROM memory_contributions
        WHERE tenant_id = \(bind: tenantID) AND memory_id = \(bind: memoryID)
        ORDER BY created_at ASC, id ASC
        """).all(decoding: ContributionRow.self)
        return MemoryProvenanceResponse(memoryID: memoryID, contributions: rows.map(\.dto))
    }

    func summaries(tenantID: UUID, memoryIDs: [UUID]) async throws -> [UUID: MemoryProvenanceSummaryDTO] {
        guard !memoryIDs.isEmpty else { return [:] }
        guard let sql = fluent.db() as? any SQLDatabase else { return [:] }
        let literal = Self.uuidArray(memoryIDs)
        let rows = try await sql.raw("""
        SELECT memory_id, id, operation, actor_kind, source_kind, provider,
               model, source_reference, created_at
        FROM memory_contributions
        WHERE tenant_id = \(bind: tenantID)
          AND memory_id = ANY(\(unsafeRaw: literal))
        ORDER BY memory_id, created_at ASC, id ASC
        """).all(decoding: SummaryRow.self)
        return Dictionary(grouping: rows, by: \.memory_id).mapValues { values in
            let contributions = values.map(\.dto)
            let models = contributions.compactMap(\.model)
            let contributors = Array(Set(models)).sorted {
                ($0.provider, $0.model) < ($1.provider, $1.model)
            }
            return MemoryProvenanceSummaryDTO(
                createdBy: contributions.first,
                lastUpdatedBy: contributions.dropFirst().last,
                contributors: contributors
            )
        }
    }

    func facets(tenantID: UUID) async throws -> MemoryFacetsResponse {
        guard let sql = fluent.db() as? any SQLDatabase else {
            throw HTTPError(.internalServerError, message: "SQL driver required for memory facets")
        }
        async let providers = facet(sql: sql, tenantID: tenantID, column: "origin_provider")
        async let models = facet(sql: sql, tenantID: tenantID, column: "origin_model")
        async let sources = facet(sql: sql, tenantID: tenantID, column: "origin_kind")
        let bounds = try await sql.raw("""
        SELECT MIN(created_at) AS oldest_at, MAX(created_at) AS newest_at
        FROM memories WHERE tenant_id = \(bind: tenantID)
        """).first(decoding: BoundsRow.self)
        return try await MemoryFacetsResponse(
            providers: providers,
            models: models,
            sources: sources,
            oldestAt: bounds?.oldest_at,
            newestAt: bounds?.newest_at
        )
    }

    func enqueueOutput(
        tenantID: UUID,
        source: MemorySourceKindDTO,
        sourceID: String,
        conversationMessageID: UUID?,
        content: String,
        provider: String?,
        model: String?
    ) async throws {
        guard let sql = fluent.db() as? any SQLDatabase else { return }
        try await sql.raw("""
        INSERT INTO memory_index_jobs
            (id, tenant_id, source_kind, source_id, conversation_message_id,
             content, provider, model, status, created_at, updated_at)
        VALUES (
            \(bind: UUID()), \(bind: tenantID), \(bind: source.rawValue),
            \(bind: sourceID), \(bind: conversationMessageID), \(bind: content),
            \(bind: provider), \(bind: model), 'pending', NOW(), NOW()
        )
        ON CONFLICT (tenant_id, source_kind, source_id) DO NOTHING
        """).run()
    }

    func suppressJob(tenantID: UUID, memory: Memory) async throws {
        guard let sourceID = memory.originSourceID,
              let sql = fluent.db() as? any SQLDatabase
        else { return }
        try await sql.raw("""
        UPDATE memory_index_jobs SET status = 'suppressed', updated_at = NOW()
        WHERE tenant_id = \(bind: tenantID)
          AND source_kind = \(bind: memory.originKind)
          AND source_id = \(bind: sourceID)
        """).run()
    }

    private func facet(
        sql: any SQLDatabase,
        tenantID: UUID,
        column: String
    ) async throws -> [MemoryFacetDTO] {
        let rows = try await sql.raw("""
        SELECT \(unsafeRaw: column) AS value, COUNT(*)::int AS count
        FROM memories
        WHERE tenant_id = \(bind: tenantID) AND \(unsafeRaw: column) IS NOT NULL
        GROUP BY \(unsafeRaw: column)
        ORDER BY count DESC, value ASC
        """).all(decoding: FacetRow.self)
        return rows.map { MemoryFacetDTO(value: $0.value, count: $0.count) }
    }

    private static func uuidArray(_ ids: [UUID]) -> String {
        "ARRAY[" + ids.map { "'\($0.uuidString)'" }.joined(separator: ",") + "]::uuid[]"
    }
}

private struct ContributionRow: Decodable {
    let id: UUID
    let operation: String
    let actor_kind: String
    let source_kind: String
    let provider: String?
    let model: String?
    let source_reference: String?
    let created_at: Date

    var dto: MemoryContributionDTO {
        MemoryContributionDTO(
            id: id,
            operation: MemoryContributionOperationDTO(rawValue: operation) ?? .update,
            actor: MemoryActorKindDTO(rawValue: actor_kind) ?? .system,
            source: MemorySourceKindDTO(rawValue: source_kind) ?? .legacy,
            model: provider.flatMap { provider in model.map { ModelProvenanceDTO(provider: provider, model: $0) } },
            sourceReference: source_reference,
            createdAt: created_at
        )
    }
}

private struct SummaryRow: Decodable {
    let memory_id: UUID
    let id: UUID
    let operation: String
    let actor_kind: String
    let source_kind: String
    let provider: String?
    let model: String?
    let source_reference: String?
    let created_at: Date

    var dto: MemoryContributionDTO {
        ContributionRow(
            id: id,
            operation: operation,
            actor_kind: actor_kind,
            source_kind: source_kind,
            provider: provider,
            model: model,
            source_reference: source_reference,
            created_at: created_at
        ).dto
    }
}

private struct FacetRow: Decodable { let value: String; let count: Int }
private struct BoundsRow: Decodable { let oldest_at: Date?; let newest_at: Date? }
