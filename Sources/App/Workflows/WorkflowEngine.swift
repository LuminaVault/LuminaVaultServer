import FluentKit
import Foundation
import HummingbirdFluent
import Logging
import LuminaVaultShared
import ServiceLifecycle
import SQLKit

/// Durable workflow worker. Postgres leases, rather than actor memory, own
/// execution so a process restart or second replica cannot double-claim work.
actor WorkflowEngine: Service {
    private let fluent: Fluent
    private let logger: Logger
    private let transport: any HermesChatTransport
    private let defaultModel: String
    private let skillRunner: SkillRunner
    private let skillCatalog: SkillCatalog
    private let embeddings: any EmbeddingService
    private let memories: MemoryRepository
    private let workerID = UUID().uuidString
    private let pollInterval: Duration

    init(fluent: Fluent, transport: any HermesChatTransport, defaultModel: String, skillRunner: SkillRunner, skillCatalog: SkillCatalog, embeddings: any EmbeddingService, logger: Logger, pollInterval: Duration = .seconds(1)) {
        self.fluent = fluent; self.transport = transport; self.defaultModel = defaultModel
        self.skillRunner = skillRunner; self.skillCatalog = skillCatalog; self.embeddings = embeddings
        memories = MemoryRepository(fluent: fluent); self.logger = logger; self.pollInterval = pollInterval
    }

    func run() async throws {
        while !Task.isCancelled {
            do {
                if let run = try await claim() {
                    await execute(run)
                } else {
                    try await Task.sleep(for: pollInterval)
                }
            } catch is CancellationError { return }
            catch { logger.error("workflow worker tick failed", metadata: ["error": "\(error)"]); try? await Task.sleep(for: pollInterval) }
        }
    }

    private func claim() async throws -> WorkflowRun? {
        guard let sql = fluent.db() as? any SQLDatabase else { return nil }
        struct Claimed: Decodable { let id: UUID }
        let now = Date(); let lease = now.addingTimeInterval(60)
        let row = try await sql.raw("""
        WITH candidate AS (
          SELECT id FROM workflow_runs
          WHERE status = 'queued' AND (lease_expires_at IS NULL OR lease_expires_at < NOW())
          ORDER BY created_at FOR UPDATE SKIP LOCKED LIMIT 1
        )
        UPDATE workflow_runs r SET status = 'running', lease_owner = \(bind: workerID),
          lease_expires_at = \(bind: lease), started_at = COALESCE(started_at, \(bind: now)), updated_at = NOW()
        FROM candidate WHERE r.id = candidate.id RETURNING r.id
        """).first(decoding: Claimed.self)
        guard let id = row?.id else { return nil }
        return try await WorkflowRun.find(id, on: fluent.db())
    }

    private func execute(_ run: WorkflowRun) async {
        do {
            let runID = try run.requireID()
            guard let version = try await WorkflowVersion.find(run.versionID, on: fluent.db()) else { throw WorkflowEngineError.missingVersion }
            let definition = version.definition
            try WorkflowValidator.validate(definition)
            let order = try topologicalOrder(definition)
            var context = run.input
            let completed = try await WorkflowNodeRun.query(on: fluent.db()).filter(\.$runID == runID).all()
            for prior in completed where prior.status == WorkflowNodeRunStatus.succeeded.rawValue {
                for (key, value) in prior.outputSnapshot ?? [:] {
                    context["nodes.\(prior.nodeID.uuidString).\(key)"] = value
                }
            }

            guard let triggerNode = order.first(where: { $0.kind == .trigger }) else { throw WorkflowEngineError.invalidGraph }
            var activated: Set<UUID> = [triggerNode.id]
            activateOutgoing(from: triggerNode, definition: definition, context: context, activated: &activated)

            let depths = nodeDepths(definition)
            let grouped = Dictionary(grouping: order.filter { $0.kind != .trigger }) { depths[$0.id, default: 0] }
            for depth in grouped.keys.sorted() {
                try Task.checkCancellation(); try await ensureRunIsActive(runID)
                let wave = grouped[depth, default: []].filter { activated.contains($0.id) }
                var runnable: [WorkflowNodeDTO] = []
                for node in wave {
                    if completed.contains(where: { $0.nodeID == node.id && $0.status == WorkflowNodeRunStatus.succeeded.rawValue }) {
                        activateOutgoing(from: node, definition: definition, context: context, activated: &activated)
                    } else if node.kind == .approval {
                        try await pauseForApproval(run: run, node: node)
                        return
                    } else {
                        runnable.append(node)
                    }
                }
                let snapshot = context
                let results = try await withThrowingTaskGroup(of: WorkflowNodeExecution.self) { group in
                    var iterator = runnable.makeIterator()
                    func submit(_ node: WorkflowNodeDTO) {
                        group.addTask { [self] in try await executePersistedNode(node, run: run, runID: runID, context: snapshot) }
                    }
                    for _ in 0 ..< min(WorkflowExecutionBounds.maxParallelNodes, runnable.count) {
                        if let node = iterator.next() {
                            submit(node)
                        }
                    }
                    var values: [WorkflowNodeExecution] = []
                    while let value = try await group.next() {
                        values.append(value)
                        if let node = iterator.next() {
                            submit(node)
                        }
                    }
                    return values
                }
                for result in results.sorted(by: { $0.node.id.uuidString < $1.node.id.uuidString }) {
                    for (key, value) in result.output {
                        context["nodes.\(result.node.id.uuidString).\(key)"] = value
                    }
                    activateOutgoing(from: result.node, definition: definition, context: context, activated: &activated)
                }
            }
            try await ensureRunIsActive(runID)
            run.status = WorkflowRunStatus.succeeded.rawValue; run.endedAt = Date(); run.leaseOwner = nil; run.leaseExpiresAt = nil
            try await run.save(on: fluent.db())
        } catch WorkflowEngineError.cancelled {
            // The API already persisted the terminal cancellation state. Do
            // not race it by converting the run to failed in this worker.
            run.leaseOwner = nil; run.leaseExpiresAt = nil
            try? await run.save(on: fluent.db())
        } catch {
            run.status = WorkflowRunStatus.failed.rawValue; run.errorMessage = String(describing: error)
            run.endedAt = Date(); run.leaseOwner = nil; run.leaseExpiresAt = nil
            try? await run.save(on: fluent.db())
        }
    }

    private func executePersistedNode(_ node: WorkflowNodeDTO, run: WorkflowRun, runID: UUID, context: [String: String]) async throws -> WorkflowNodeExecution {
        let nodeRun = WorkflowNodeRun()
        nodeRun.id = UUID(); nodeRun.runID = runID; nodeRun.nodeID = node.id; nodeRun.nodeName = node.name
        nodeRun.status = WorkflowNodeRunStatus.running.rawValue; nodeRun.attempt = 1
        nodeRun.startedAt = Date(); nodeRun.inputSnapshot = redact(context)
        try await nodeRun.create(on: fluent.db())
        do {
            let output = try await executeNode(node, run: run, context: context)
            nodeRun.outputSnapshot = redact(output); nodeRun.status = WorkflowNodeRunStatus.succeeded.rawValue; nodeRun.endedAt = Date()
            try await nodeRun.save(on: fluent.db())
            return WorkflowNodeExecution(node: node, output: output)
        } catch {
            nodeRun.status = WorkflowNodeRunStatus.failed.rawValue; nodeRun.errorMessage = String(describing: error); nodeRun.endedAt = Date()
            try await nodeRun.save(on: fluent.db()); throw error
        }
    }

    private func ensureRunIsActive(_ runID: UUID) async throws {
        guard let current = try await WorkflowRun.find(runID, on: fluent.db()),
              current.status != WorkflowRunStatus.cancelled.rawValue
        else { throw WorkflowEngineError.cancelled }
    }

    private func pauseForApproval(run: WorkflowRun, node: WorkflowNodeDTO) async throws {
        let runID = try run.requireID()
        if try await WorkflowApproval.query(on: fluent.db()).filter(\.$runID == runID).filter(\.$nodeID == node.id).first() == nil {
            let nodeRun = WorkflowNodeRun(); nodeRun.id = UUID(); nodeRun.runID = runID; nodeRun.nodeID = node.id
            nodeRun.nodeName = node.name; nodeRun.status = WorkflowNodeRunStatus.waitingForApproval.rawValue
            nodeRun.attempt = 1; nodeRun.startedAt = Date(); try await nodeRun.create(on: fluent.db())
            let approval = WorkflowApproval(); approval.id = UUID(); approval.tenantID = run.tenantID
            approval.runID = runID; approval.workflowID = run.workflowID; approval.nodeID = node.id
            approval.title = node.name; approval.message = node.configuration["message"]
            approval.status = "pending"; approval.expiresAt = Date().addingTimeInterval(24 * 60 * 60)
            try await approval.create(on: fluent.db())
        }
        run.status = WorkflowRunStatus.waitingForApproval.rawValue; run.leaseOwner = nil; run.leaseExpiresAt = nil
        try await run.save(on: fluent.db())
    }

    private func executeNode(_ node: WorkflowNodeDTO, run: WorkflowRun, context: [String: String]) async throws -> [String: String] {
        switch node.kind {
        case .template, .output:
            let source = node.configuration["value"] ?? node.configuration["template"] ?? ""
            return ["text": interpolate(source, context: context)]
        case .condition:
            let lhs = interpolate(node.configuration["left"] ?? "", context: context)
            let rhs = interpolate(node.configuration["right"] ?? "", context: context)
            let matches = node.configuration["operator"] == "notEquals" ? lhs != rhs : lhs == rhs
            return ["result": matches ? "true" : "false", "text": matches ? "true" : "false"]
        case .llm:
            let prompt = interpolate(node.configuration["prompt"] ?? node.configuration["value"] ?? "", context: context)
            let model = node.configuration["model"] ?? defaultModel
            let payload = try JSONSerialization.data(withJSONObject: [
                "model": model,
                "messages": [["role": "user", "content": prompt]],
                "stream": false,
            ])
            let response = try await transport.chatCompletions(payload: payload, sessionKey: run.tenantID.uuidString, sessionID: run.conversationID?.uuidString)
            guard let json = try JSONSerialization.jsonObject(with: response) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any],
                  let text = message["content"] as? String
            else { throw WorkflowEngineError.invalidLLMResponse }
            return ["text": text, "model": model]
        case .skill:
            guard let name = node.configuration["skillName"],
                  let manifest = try await skillCatalog.manifest(named: name, for: run.tenantID),
                  let user = try await User.find(run.tenantID, on: fluent.db())
            else { throw WorkflowEngineError.executorUnavailable("skill") }
            let result = try await skillRunner.run(skill: manifest, tenantID: run.tenantID, tier: user.tier, profileUsername: user.username, trigger: .event(name: "workflow"), input: interpolate(node.configuration["input"] ?? "", context: context))
            return ["text": result.markdown, "model": result.modelUsed ?? ""]
        case .memorySearch:
            let query = interpolate(node.configuration["query"] ?? node.configuration["value"] ?? "", context: context)
            let vector = try await embeddings.embed(query, tenantID: run.tenantID)
            let hits = try await memories.semanticSearch(tenantID: run.tenantID, queryEmbedding: vector, limit: min(20, Int(node.configuration["limit"] ?? "5") ?? 5))
            return ["text": hits.map(\.content).joined(separator: "\n\n")]
        case .memoryWrite:
            let text = interpolate(node.configuration["content"] ?? node.configuration["value"] ?? "", context: context)
            let vector = try await embeddings.embed(text, tenantID: run.tenantID)
            let memory = try await memories.create(tenantID: run.tenantID, content: text, embedding: vector)
            return try ["text": text, "memoryID": (memory.requireID()).uuidString]
        case .parallel:
            return [:]
        case .forEach:
            return try await executeForEach(node, run: run, context: context)
        case .whileLoop:
            return try await executeWhile(node, run: run, context: context)
        case .trigger, .approval:
            return [:]
        }
    }

    private func executeForEach(_ node: WorkflowNodeDTO, run _: WorkflowRun, context: [String: String]) async throws -> [String: String] {
        let raw = interpolate(node.configuration["items"] ?? "", context: context)
        let items = parseItems(raw)
        let limit = boundedIterations(node.configuration["maxIterations"])
        guard items.count <= limit else { throw WorkflowEngineError.iterationLimitExceeded(limit) }
        let concurrency = min(max(Int(node.configuration["concurrency"] ?? "4") ?? 4, 1), WorkflowExecutionBounds.maxParallelNodes)
        var outputs = Array(repeating: "", count: items.count)
        try await withThrowingTaskGroup(of: (Int, String).self) { group in
            var next = 0
            func submit(_ index: Int) {
                group.addTask { [self] in
                    try Task.checkCancellation()
                    var iterationContext = context
                    iterationContext["item"] = items[index]; iterationContext["index"] = String(index)
                    return (index, interpolate(node.configuration["template"] ?? "{{item}}", context: iterationContext))
                }
            }
            while next < min(concurrency, items.count) {
                submit(next); next += 1
            }
            while let (index, value) = try await group.next() {
                outputs[index] = value
                if next < items.count {
                    submit(next); next += 1
                }
            }
        }
        return ["text": outputs.joined(separator: node.configuration["separator"] ?? "\n"), "count": String(outputs.count)]
    }

    private func executeWhile(_ node: WorkflowNodeDTO, run _: WorkflowRun, context: [String: String]) async throws -> [String: String] {
        let limit = boundedIterations(node.configuration["maxIterations"])
        let target = node.configuration["equals"] ?? "true"
        var previous = ""; var outputs: [String] = []
        for index in 0 ..< limit {
            try Task.checkCancellation()
            var iterationContext = context
            iterationContext["iteration"] = String(index); iterationContext["previous"] = previous
            let condition = interpolate(node.configuration["condition"] ?? "false", context: iterationContext)
            guard condition == target else { return ["text": outputs.joined(separator: "\n"), "count": String(outputs.count)] }
            previous = interpolate(node.configuration["template"] ?? "{{previous}}", context: iterationContext)
            outputs.append(previous)
        }
        throw WorkflowEngineError.iterationLimitExceeded(limit)
    }

    private func parseItems(_ raw: String) -> [String] {
        if let data = raw.data(using: .utf8), let values = try? JSONDecoder().decode([String].self, from: data) {
            return values
        }
        return raw.split(whereSeparator: { $0 == "," || $0.isNewline }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.isEmpty == false }
    }

    private func boundedIterations(_ raw: String?) -> Int {
        min(max(Int(raw ?? "20") ?? 20, 1), WorkflowExecutionBounds.maxIterations)
    }

    private nonisolated func interpolate(_ value: String, context: [String: String]) -> String {
        context.reduce(value) { result, pair in result.replacingOccurrences(of: "{{\(pair.key)}}", with: pair.value) }
    }

    private func redact(_ values: [String: String]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: values.map { key, value in
            let sensitive = ["secret", "token", "password", "authorization", "key"].contains { key.localizedCaseInsensitiveContains($0) }
            return (key, sensitive ? "[REDACTED]" : String(value.prefix(16384)))
        })
    }

    private func activateOutgoing(from node: WorkflowNodeDTO, definition: WorkflowDefinitionDTO, context: [String: String], activated: inout Set<UUID>) {
        let result = context["nodes.\(node.id.uuidString).result"]
        for edge in definition.edges where edge.sourceNodeID == node.id {
            if node.kind == .condition, ["true", "false"].contains(edge.sourcePort), edge.sourcePort != result {
                continue
            }
            activated.insert(edge.targetNodeID)
        }
    }

    private func topologicalOrder(_ definition: WorkflowDefinitionDTO) throws -> [WorkflowNodeDTO] {
        var indegree = Dictionary(uniqueKeysWithValues: definition.nodes.map { ($0.id, 0) })
        for edge in definition.edges {
            indegree[edge.targetNodeID, default: 0] += 1
        }
        var queue = indegree.filter { $0.value == 0 }.map(\.key); var result: [WorkflowNodeDTO] = []
        while let id = queue.popLast() {
            if let node = definition.nodes.first(where: { $0.id == id }) {
                result.append(node)
            }
            for target in definition.edges.lazy.filter({ $0.sourceNodeID == id }).map(\.targetNodeID) {
                indegree[target, default: 0] -= 1; if indegree[target] == 0 {
                    queue.append(target)
                }
            }
        }
        guard result.count == definition.nodes.count else { throw WorkflowEngineError.invalidGraph }
        return result
    }

    private func nodeDepths(_ definition: WorkflowDefinitionDTO) -> [UUID: Int] {
        var depths: [UUID: Int] = [:]
        for node in (try? topologicalOrder(definition)) ?? [] {
            let parents = definition.edges.filter { $0.targetNodeID == node.id }.map(\.sourceNodeID)
            depths[node.id] = (parents.compactMap { depths[$0] }.max() ?? -1) + 1
        }
        return depths
    }
}

private struct WorkflowNodeExecution { let node: WorkflowNodeDTO; let output: [String: String] }
enum WorkflowExecutionBounds { static let maxIterations = 20; static let maxParallelNodes = 8 }
private enum WorkflowEngineError: Error { case missingVersion, invalidGraph, invalidLLMResponse, executorUnavailable(String), iterationLimitExceeded(Int), cancelled }
