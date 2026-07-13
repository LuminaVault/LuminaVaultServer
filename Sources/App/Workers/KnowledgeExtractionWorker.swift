import Crypto
import FluentKit
import Foundation
import HummingbirdFluent
import Logging
import ServiceLifecycle
import SQLKit

/// Durable graph extraction. The deterministic extractor is intentionally the
/// correctness baseline; an LLM extractor can enrich the same schema later.
actor KnowledgeExtractionWorker: Service {
    let fluent: Fluent
    let logger: Logger
    let tickInterval: Duration
    let push: APNSNotificationService?

    init(
        fluent: Fluent,
        push: APNSNotificationService? = nil,
        logger: Logger = Logger(label: "lv.knowledge.extraction.worker"),
        tickInterval: Duration = .seconds(2)
    ) {
        self.fluent = fluent
        self.push = push
        self.logger = logger
        self.tickInterval = tickInterval
    }

    func run() async throws {
        logger.info("knowledge extraction worker started")
        while !Task.isCancelled {
            do {
                if try await tick() == 0 {
                    try await Task.sleep(for: tickInterval)
                }
            } catch is CancellationError {
                return
            } catch {
                logger.warning("knowledge extraction tick failed: \(error)")
                try? await Task.sleep(for: tickInterval)
            }
        }
    }

    @discardableResult
    func tick() async throws -> Int {
        guard let sql = fluent.db() as? any SQLDatabase else { return 0 }
        try await enqueueNextChangedMemory(sql: sql)
        guard let job = try await claimJob(sql: sql) else { return 0 }
        do {
            try await extract(job: job, sql: sql)
            try await finalizeIngestion(job: job, sql: sql)
            try await sql.raw("""
            UPDATE knowledge_extraction_jobs
            SET status = 'completed', last_error = NULL, updated_at = NOW()
            WHERE id = \(bind: job.id)
            """).run()
        } catch {
            let delay = min(3600, 1 << min(job.attempts, 10))
            try await sql.raw("""
            UPDATE knowledge_extraction_jobs
            SET status = 'retry', last_error = \(bind: String(String(describing: error).prefix(500))),
                next_attempt_at = NOW() + (\(bind: delay) * INTERVAL '1 second'), updated_at = NOW()
            WHERE id = \(bind: job.id)
            """).run()
            throw error
        }
        return 1
    }

    private func enqueueNextChangedMemory(sql: any SQLDatabase) async throws {
        try await sql.raw("""
        INSERT INTO knowledge_extraction_jobs (id, tenant_id, memory_id, content_fingerprint)
        SELECT uuid_generate_v4(), m.tenant_id, m.id,
               encode(digest(m.content, 'sha256'), 'hex')
        FROM memories m
        WHERE NOT EXISTS (
            SELECT 1 FROM knowledge_extraction_jobs j
            WHERE j.tenant_id = m.tenant_id AND j.memory_id = m.id
              AND j.content_fingerprint = encode(digest(m.content, 'sha256'), 'hex')
        )
        ORDER BY m.created_at ASC
        LIMIT 1
        ON CONFLICT DO NOTHING
        """).run()
    }

    private func claimJob(sql: any SQLDatabase) async throws -> ExtractionJobRow? {
        try await sql.raw("""
        WITH candidate AS (
            SELECT id FROM knowledge_extraction_jobs
            WHERE status IN ('pending', 'retry') AND next_attempt_at <= NOW()
            ORDER BY created_at ASC
            FOR UPDATE SKIP LOCKED
            LIMIT 1
        )
        UPDATE knowledge_extraction_jobs j
        SET status = 'processing', attempts = attempts + 1, updated_at = NOW()
        FROM candidate
        WHERE j.id = candidate.id
        RETURNING j.id, j.tenant_id, j.memory_id, j.content_fingerprint, j.attempts,
                  (SELECT content FROM memories WHERE id = j.memory_id AND tenant_id = j.tenant_id) AS content,
                  (SELECT source_vault_file_id FROM memories WHERE id = j.memory_id AND tenant_id = j.tenant_id) AS source_vault_file_id
        """).first(decoding: ExtractionJobRow.self)
    }

    private func extract(job: ExtractionJobRow, sql: any SQLDatabase) async throws {
        let statements = Self.statements(from: job.content)
        try await sql.raw("DELETE FROM knowledge_evidence WHERE tenant_id = \(bind: job.tenant_id) AND memory_id = \(bind: job.memory_id)").run()

        var claims: [(id: UUID, text: String, entities: [String])] = []
        for statement in statements {
            let claimID = try await upsertNode(
                sql: sql, tenantID: job.tenant_id, kind: "claim",
                key: Self.fingerprint(statement.lowercased()), label: statement,
                summary: nil, confidence: 1
            )
            try await addEvidence(sql: sql, job: job, nodeID: claimID, edgeID: nil, quote: statement)
            let entities = Self.entities(in: statement)
            claims.append((claimID, statement, entities))
            for entity in entities {
                let entityID = try await upsertNode(
                    sql: sql, tenantID: job.tenant_id, kind: "entity",
                    key: Self.canonical(entity), label: entity,
                    summary: nil, confidence: 0.85
                )
                try await addEvidence(sql: sql, job: job, nodeID: entityID, edgeID: nil, quote: statement)
                let edgeID = try await upsertEdge(
                    sql: sql, tenantID: job.tenant_id, from: claimID, to: entityID,
                    predicate: "mentions", state: "asserted", confidence: 1,
                    rationale: "The source statement explicitly mentions \(entity).",
                    fingerprint: job.content_fingerprint
                )
                try await addEvidence(sql: sql, job: job, nodeID: nil, edgeID: edgeID, quote: statement)
            }
            if Self.looksLikeEvent(statement) {
                let eventID = try await upsertNode(
                    sql: sql, tenantID: job.tenant_id, kind: "event",
                    key: Self.fingerprint(statement.lowercased()), label: statement,
                    summary: "Dated or time-qualified event", confidence: 0.8
                )
                try await addEvidence(sql: sql, job: job, nodeID: eventID, edgeID: nil, quote: statement)
                let edgeID = try await upsertEdge(
                    sql: sql, tenantID: job.tenant_id, from: claimID, to: eventID,
                    predicate: "derived_from", state: "asserted", confidence: 1,
                    rationale: "The event is derived directly from this statement.",
                    fingerprint: job.content_fingerprint
                )
                try await addEvidence(sql: sql, job: job, nodeID: nil, edgeID: edgeID, quote: statement)
            }
            try await extractExplicitRelations(statement: statement, job: job, sql: sql)
        }
        try await inferWithinMemory(claims: claims, job: job, sql: sql)
        try await inferAcrossMemories(claims: claims, job: job, sql: sql)
        try await sql.raw("""
        DELETE FROM knowledge_edges e
        WHERE e.tenant_id = \(bind: job.tenant_id)
          AND NOT EXISTS (SELECT 1 FROM knowledge_evidence x WHERE x.edge_id = e.id)
        """).run()
        try await sql.raw("""
        DELETE FROM knowledge_nodes n
        WHERE n.tenant_id = \(bind: job.tenant_id)
          AND NOT EXISTS (SELECT 1 FROM knowledge_evidence x WHERE x.node_id = n.id)
          AND NOT EXISTS (SELECT 1 FROM knowledge_edges e WHERE e.from_node_id = n.id OR e.to_node_id = n.id)
        """).run()
    }

    private func extractExplicitRelations(
        statement: String,
        job: ExtractionJobRow,
        sql: any SQLDatabase
    ) async throws {
        guard let relation = Self.explicitRelation(in: statement) else { return }
        let fromID = try await upsertNode(
            sql: sql, tenantID: job.tenant_id, kind: "claim",
            key: Self.fingerprint(relation.from.lowercased()), label: relation.from,
            summary: nil, confidence: 1
        )
        let toID = try await upsertNode(
            sql: sql, tenantID: job.tenant_id, kind: "claim",
            key: Self.fingerprint(relation.to.lowercased()), label: relation.to,
            summary: nil, confidence: 1
        )
        try await addEvidence(sql: sql, job: job, nodeID: fromID, edgeID: nil, quote: statement)
        try await addEvidence(sql: sql, job: job, nodeID: toID, edgeID: nil, quote: statement)
        let edgeID = try await upsertEdge(
            sql: sql, tenantID: job.tenant_id, from: fromID, to: toID,
            predicate: relation.predicate, state: "asserted", confidence: 1,
            rationale: "The source explicitly states this \(relation.predicate.replacingOccurrences(of: "_", with: " ")) relationship.",
            fingerprint: Self.fingerprint("\(job.content_fingerprint)|\(statement)|\(relation.predicate)")
        )
        try await addEvidence(sql: sql, job: job, nodeID: nil, edgeID: edgeID, quote: statement)

        let fromEntityID = try await upsertNode(
            sql: sql, tenantID: job.tenant_id, kind: "entity",
            key: Self.canonical(relation.from), label: relation.from,
            summary: nil, confidence: 0.9
        )
        let toEntityID = try await upsertNode(
            sql: sql, tenantID: job.tenant_id, kind: "entity",
            key: Self.canonical(relation.to), label: relation.to,
            summary: nil, confidence: 0.9
        )
        try await addEvidence(sql: sql, job: job, nodeID: fromEntityID, edgeID: nil, quote: statement)
        try await addEvidence(sql: sql, job: job, nodeID: toEntityID, edgeID: nil, quote: statement)
        if fromEntityID != toEntityID {
            let entityEdgeID = try await upsertEdge(
                sql: sql, tenantID: job.tenant_id, from: fromEntityID, to: toEntityID,
                predicate: relation.predicate, state: "asserted", confidence: 0.9,
                rationale: "The source explicitly relates these entities.",
                fingerprint: Self.fingerprint("entity|\(job.content_fingerprint)|\(statement)|\(relation.predicate)")
            )
            try await addEvidence(sql: sql, job: job, nodeID: nil, edgeID: entityEdgeID, quote: statement)
        }
    }

    private func finalizeIngestion(job: ExtractionJobRow, sql: any SQLDatabase) async throws {
        struct FinalizedRow: Decodable { let id: UUID; let tenant_id: UUID; let batch_id: UUID; let file_name: String? }
        let rows = try await sql.raw("""
        UPDATE ingestion_items
        SET state = 'completed', graph_ready_at = NOW(), lease_expires_at = NULL,
            next_attempt_at = NULL, error_message = NULL, updated_at = NOW()
        WHERE tenant_id = \(bind: job.tenant_id) AND memory_id = \(bind: job.memory_id)
          AND state = 'analyzing'
        RETURNING id, tenant_id, batch_id, file_name
        """).all(decoding: FinalizedRow.self)
        for row in rows {
            IngestionMetrics.completed.increment()
            try await sql.raw("""
            INSERT INTO ingestion_events (tenant_id, batch_id, item_id, type, state)
            VALUES (\(bind: row.tenant_id), \(bind: row.batch_id), \(bind: row.id), 'terminal', 'completed')
            """).run()
            try await sql.raw("""
            UPDATE ingestion_batches SET state = CASE
              WHEN NOT EXISTS (SELECT 1 FROM ingestion_items i WHERE i.batch_id = \(bind: row.batch_id) AND i.state <> 'completed')
              THEN 'completed' ELSE 'active' END, updated_at = NOW()
            WHERE id = \(bind: row.batch_id) AND tenant_id = \(bind: row.tenant_id)
            """).run()
            if let push {
                do {
                    try await push.notifyIngestion(userID: row.tenant_id, completed: true, fileName: row.file_name)
                    try await sql.raw("UPDATE ingestion_items SET terminal_notified_at = NOW() WHERE id = \(bind: row.id) AND terminal_notified_at IS NULL").run()
                } catch {
                    IngestionMetrics.apnsFailures.increment()
                    logger.warning("ingestion terminal push failed item=\(row.id): \(error)")
                }
            }
        }
    }

    private func inferWithinMemory(
        claims: [(id: UUID, text: String, entities: [String])],
        job: ExtractionJobRow,
        sql: any SQLDatabase
    ) async throws {
        for leftIndex in claims.indices {
            for rightIndex in claims.indices where rightIndex > leftIndex {
                let left = claims[leftIndex], right = claims[rightIndex]
                guard !Set(left.entities).isDisjoint(with: right.entities) else { continue }
                let leftNegative = Self.isNegative(left.text)
                let rightNegative = Self.isNegative(right.text)
                let predicate = leftNegative != rightNegative ? "contradicts" : "related_to"
                let confidence = predicate == "contradicts" ? 0.55 : 0.65
                let rationale = predicate == "contradicts"
                    ? "These statements concern the same entity but use opposing polarity; review the source context."
                    : "These statements share a named entity."
                let evidenceFingerprint = Self.fingerprint([job.content_fingerprint, left.text, right.text, predicate].joined(separator: "|"))
                let edgeID = try await upsertEdge(
                    sql: sql, tenantID: job.tenant_id, from: left.id, to: right.id,
                    predicate: predicate, state: "suggested", confidence: confidence,
                    rationale: rationale, fingerprint: evidenceFingerprint
                )
                try await addEvidence(sql: sql, job: job, nodeID: nil, edgeID: edgeID, quote: left.text)
                try await addEvidence(sql: sql, job: job, nodeID: nil, edgeID: edgeID, quote: right.text)
            }
        }
    }

    /// Generates cross-memory candidates only when two claims share an
    /// extracted entity. Opposing polarity is a low-confidence contradiction
    /// suggestion; all other pairs are reviewable related-to suggestions.
    private func inferAcrossMemories(
        claims: [(id: UUID, text: String, entities: [String])],
        job: ExtractionJobRow,
        sql: any SQLDatabase
    ) async throws {
        guard claims.isEmpty == false else { return }
        let rows = try await sql.raw("""
        SELECT DISTINCT current_claim.id AS current_id,
               current_claim.label AS current_label,
               other_claim.id AS other_id,
               other_claim.label AS other_label
        FROM knowledge_nodes current_claim
        JOIN knowledge_edges current_mentions
          ON current_mentions.tenant_id = \(bind: job.tenant_id)
         AND current_mentions.from_node_id = current_claim.id
         AND current_mentions.predicate = 'mentions'
        JOIN knowledge_edges other_mentions
          ON other_mentions.tenant_id = current_mentions.tenant_id
         AND other_mentions.to_node_id = current_mentions.to_node_id
         AND other_mentions.predicate = 'mentions'
        JOIN knowledge_nodes other_claim ON other_claim.id = other_mentions.from_node_id
        WHERE current_claim.tenant_id = \(bind: job.tenant_id)
          AND current_claim.id = ANY(\(unsafeRaw: Self.uuidArray(claims.map(\.id))))
          AND other_claim.id <> current_claim.id
        LIMIT 200
        """).all(decoding: ClaimPairRow.self)

        for row in rows {
            let predicate = Self.isNegative(row.current_label) != Self.isNegative(row.other_label)
                ? "contradicts" : "related_to"
            let ordered = row.current_id.uuidString < row.other_id.uuidString
                ? (row.current_id, row.other_id) : (row.other_id, row.current_id)
            let fingerprint = Self.fingerprint("\(ordered.0)|\(ordered.1)|\(predicate)")
            let rationale = predicate == "contradicts"
                ? "Claims from different memories concern the same entity but use opposing polarity; review both sources."
                : "Claims from different memories share a named entity."
            let edgeID = try await upsertEdge(
                sql: sql, tenantID: job.tenant_id, from: ordered.0, to: ordered.1,
                predicate: predicate, state: "suggested",
                confidence: predicate == "contradicts" ? 0.6 : 0.65,
                rationale: rationale, fingerprint: fingerprint
            )
            try await addEvidenceFromNodes(
                sql: sql, tenantID: job.tenant_id,
                nodeIDs: [row.current_id, row.other_id], edgeID: edgeID
            )
        }
    }

    private func upsertNode(
        sql: any SQLDatabase,
        tenantID: UUID,
        kind: String,
        key: String,
        label: String,
        summary: String?,
        confidence: Double
    ) async throws -> UUID {
        struct IDRow: Decodable { let id: UUID }
        let id = UUID()
        let row = try await sql.raw("""
        INSERT INTO knowledge_nodes (id, tenant_id, kind, canonical_key, label, summary, confidence)
        VALUES (\(bind: id), \(bind: tenantID), \(bind: kind), \(bind: key), \(bind: label), \(bind: summary), \(bind: confidence))
        ON CONFLICT (tenant_id, kind, canonical_key) DO UPDATE
        SET label = EXCLUDED.label, summary = COALESCE(EXCLUDED.summary, knowledge_nodes.summary),
            confidence = GREATEST(knowledge_nodes.confidence, EXCLUDED.confidence), updated_at = NOW()
        RETURNING id
        """).first(decoding: IDRow.self)
        guard let row else { throw ExtractionError.missingInsertedID }
        return row.id
    }

    private func upsertEdge(
        sql: any SQLDatabase,
        tenantID: UUID,
        from: UUID,
        to: UUID,
        predicate: String,
        state: String,
        confidence: Double,
        rationale: String,
        fingerprint: String
    ) async throws -> UUID {
        struct IDRow: Decodable { let id: UUID }
        let row = try await sql.raw("""
        INSERT INTO knowledge_edges (
            id, tenant_id, from_node_id, to_node_id, predicate, state,
            confidence, rationale, evidence_fingerprint
        ) VALUES (
            \(bind: UUID()), \(bind: tenantID), \(bind: from), \(bind: to), \(bind: predicate), \(bind: state),
            \(bind: confidence), \(bind: rationale), \(bind: fingerprint)
        )
        ON CONFLICT (tenant_id, from_node_id, to_node_id, predicate, evidence_fingerprint) DO UPDATE
        SET confidence = EXCLUDED.confidence, rationale = EXCLUDED.rationale, updated_at = NOW(),
            state = CASE WHEN knowledge_edges.state IN ('confirmed', 'dismissed') THEN knowledge_edges.state ELSE EXCLUDED.state END
        RETURNING id
        """).first(decoding: IDRow.self)
        guard let row else { throw ExtractionError.missingInsertedID }
        return row.id
    }

    private func addEvidence(
        sql: any SQLDatabase,
        job: ExtractionJobRow,
        nodeID: UUID?,
        edgeID: UUID?,
        quote: String
    ) async throws {
        try await sql.raw("""
        INSERT INTO knowledge_evidence (
            id, tenant_id, node_id, edge_id, memory_id, source_vault_file_id, quote
        ) VALUES (
            \(bind: UUID()), \(bind: job.tenant_id), \(bind: nodeID), \(bind: edgeID),
            \(bind: job.memory_id), \(bind: job.source_vault_file_id), \(bind: quote)
        )
        """).run()
    }

    private func addEvidenceFromNodes(
        sql: any SQLDatabase,
        tenantID: UUID,
        nodeIDs: [UUID],
        edgeID: UUID
    ) async throws {
        try await sql.raw("""
        INSERT INTO knowledge_evidence (
            id, tenant_id, edge_id, memory_id, source_vault_file_id,
            quote, start_offset, end_offset
        )
        SELECT uuid_generate_v4(), e.tenant_id, \(bind: edgeID), e.memory_id,
               e.source_vault_file_id, e.quote, e.start_offset, e.end_offset
        FROM knowledge_evidence e
        WHERE e.tenant_id = \(bind: tenantID)
          AND e.node_id = ANY(\(unsafeRaw: Self.uuidArray(nodeIDs)))
          AND NOT EXISTS (
              SELECT 1 FROM knowledge_evidence existing
              WHERE existing.edge_id = \(bind: edgeID)
                AND existing.memory_id = e.memory_id
                AND existing.quote = e.quote
          )
        """).run()
    }

    static func statements(from content: String) -> [String] {
        let fragments: [Substring] = content.split(whereSeparator: { character in
            character == "." || character == "!" || character == "?" || character == "\n"
        })
        let trimmed = fragments.map { fragment in
            String(fragment).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let meaningful = trimmed.filter { $0.count >= 12 }
        return Array(meaningful.prefix(40))
    }

    static func entities(in statement: String) -> [String] {
        let words = statement.split(whereSeparator: { !$0.isLetter && $0 != "-" }).map(String.init)
        var result: [String] = []
        var phrase: [String] = []
        func flush() {
            guard !phrase.isEmpty else { return }
            let value = phrase.joined(separator: " ")
            if value.count > 2, !["I", "The", "This", "That"].contains(value) {
                result.append(value)
            }
            phrase.removeAll(keepingCapacity: true)
        }
        for word in words {
            if word.first?.isUppercase == true {
                phrase.append(word)
            } else {
                flush()
            }
        }
        flush()
        var seen: Set<String> = []
        let unique = result.filter { seen.insert(canonical($0)).inserted }
        return Array(unique.prefix(12))
    }

    static func looksLikeEvent(_ statement: String) -> Bool {
        let lower = statement.lowercased()
        let markers = ["today", "tomorrow", "yesterday", " on ", " at ", "during", "after", "before", "when"]
        return markers.contains { lower.contains($0) } || lower.range(of: #"\b(19|20)\d{2}\b"#, options: .regularExpression) != nil
    }

    static func isNegative(_ statement: String) -> Bool {
        let lower = " \(statement.lowercased()) "
        return [" not ", " never ", " no ", " cannot ", " can't ", " won't ", " isn't ", " don't "].contains { lower.contains($0) }
    }

    static func explicitRelation(in statement: String) -> (from: String, to: String, predicate: String)? {
        let lower = statement.lowercased()
        if let range = statement.range(of: " because ", options: .caseInsensitive) {
            let effect = statement[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            let cause = statement[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            if cause.count >= 4, effect.count >= 4 {
                return (cause, effect, "causes")
            }
        }
        for marker in [" caused ", " led to ", " resulted in "] {
            if let range = statement.range(of: marker, options: .caseInsensitive) {
                let cause = statement[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
                let effect = statement[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                if cause.count >= 4, effect.count >= 4 {
                    return (cause, effect, "causes")
                }
            }
        }
        if lower.hasPrefix("after "), let comma = statement.firstIndex(of: ",") {
            let before = statement[statement.index(statement.startIndex, offsetBy: 6) ..< comma]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let after = statement[statement.index(after: comma)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if before.count >= 4, after.count >= 4 {
                return (before, after, "precedes")
            }
        }
        return nil
    }

    static func canonical(_ value: String) -> String {
        value.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: " ")
    }

    static func fingerprint(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func uuidArray(_ ids: [UUID]) -> String {
        guard ids.isEmpty == false else { return "ARRAY[]::uuid[]" }
        return "ARRAY[" + ids.map { "'\($0.uuidString)'::uuid" }.joined(separator: ",") + "]"
    }
}

private struct ExtractionJobRow: Decodable {
    let id: UUID
    let tenant_id: UUID
    let memory_id: UUID
    let content_fingerprint: String
    let attempts: Int
    let content: String
    let source_vault_file_id: UUID?
}

private struct ClaimPairRow: Decodable {
    let current_id: UUID
    let current_label: String
    let other_id: UUID
    let other_label: String
}

private enum ExtractionError: Error {
    case missingInsertedID
}
