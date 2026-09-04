import FluentKit
import Foundation
import HummingbirdFluent
import Logging
import LuminaVaultShared
import ServiceLifecycle

enum HermesRunsServiceError: Error, Equatable {
    case runNotFound
    case conversationNotFound
    case tooManyActiveRuns
    case approvalNotPending
    case runNotActive
    case emptyPrompt

    var stableCode: String {
        switch self {
        case .runNotFound: "hermes_run_not_found"
        case .conversationNotFound: "conversation_not_found"
        case .tooManyActiveRuns: "hermes_runs_limit"
        case .approvalNotPending: "hermes_approval_not_pending"
        case .runNotActive: "hermes_run_not_active"
        case .emptyPrompt: "prompt_required"
        }
    }
}

/// Phase 1 — Hermes runs. Starts runs on the tenant's Hermes, owns one
/// watcher task per active run (bounded per tenant and per process), and
/// serves the persisted view. Request handlers never block on Hermes
/// events: `start` returns as soon as Hermes has acknowledged the run.
///
/// Watchers are tracked `Task`s (the daemon pattern: the actor owns the
/// handles, `stop` / shutdown cancel them, `run()` awaits them on graceful
/// shutdown). On boot `run()` re-attaches watchers for rows that are still
/// active and younger than `reattachWindow` (Hermes' own run TTL) and marks
/// older ones `lost`.
actor HermesRunsService: Service {
    struct Limits: Sendable {
        var maxWatchersPerTenant = 8
        var maxWatchersPerProcess = 32
        /// Matches the Hermes run store TTL (`api_server.py` `_RUN_STREAM_TTL`).
        var reattachWindow: TimeInterval = 300
        var capabilityCacheTTL: TimeInterval = 3600
        var watcher = HermesRunWatcher.Config()
    }

    typealias ResolveEndpoint = @Sendable (UUID) async throws -> HermesEndpointResolver.Resolution
    typealias ClientFactory = @Sendable (_ resolution: HermesEndpointResolver.Resolution, _ sessionKey: String?) -> HermesRunsClient

    private struct WatcherHandle {
        let tenantID: UUID
        let task: Task<Void, Never>
    }

    private struct CachedCapability {
        let supportsRuns: Bool
        let checkedAt: Date
    }

    private let store: HermesRunStore
    private let notifier: any HermesRunPushNotifying
    private let resolve: ResolveEndpoint
    private let makeClient: ClientFactory
    private let limits: Limits
    private let logger: Logger
    private var watchers: [UUID: WatcherHandle] = [:]
    private var capabilityCache: [String: CachedCapability] = [:]

    init(
        fluent: Fluent,
        eventBus: EventBus,
        notifier: any HermesRunPushNotifying,
        resolve: @escaping ResolveEndpoint,
        makeClient: @escaping ClientFactory,
        limits: Limits = Limits(),
        logger: Logger,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        store = HermesRunStore(fluent: fluent, eventBus: eventBus, logger: logger, now: now)
        self.notifier = notifier
        self.resolve = resolve
        self.makeClient = makeClient
        self.limits = limits
        self.logger = logger
    }

    // MARK: - ServiceLifecycle

    func run() async throws {
        await reattach()
        try? await gracefulShutdown()
        let active = watchers
        watchers.removeAll()
        for handle in active.values {
            handle.task.cancel()
        }
        for handle in active.values {
            await handle.task.value
        }
        logger.info("hermes runs service stopped", metadata: ["watchers_cancelled": .stringConvertible(active.count)])
    }

    /// Re-attach watchers to runs that were active when the process last
    /// stopped. Public for tests and callable more than once (rows already
    /// watched are skipped).
    func reattach() async {
        let rows: [HermesRun]
        do {
            rows = try await store.activeRuns()
        } catch {
            logger.error("hermes runs re-attach scan failed: \(Logger.redact(String(describing: error)))")
            return
        }
        let now = store.now()
        var attached = 0
        var lost = 0
        for run in rows {
            guard let id = run.id, watchers[id] == nil else { continue }
            if now.timeIntervalSince(run.startedAt) > limits.reattachWindow {
                await markLost(run, reason: "watcher lost across restart; run older than \(Int(limits.reattachWindow)) s")
                lost += 1
                continue
            }
            do {
                let resolution = try await resolve(run.tenantID)
                let client = makeClient(resolution, nil)
                try spawnWatcher(for: run, client: client, mode: .poll)
                attached += 1
            } catch {
                await markLost(run, reason: "watcher could not re-attach: \(Logger.redact(String(describing: error)))")
                lost += 1
            }
        }
        if attached > 0 || lost > 0 {
            logger.info("hermes runs re-attach", metadata: ["attached": .stringConvertible(attached), "lost": .stringConvertible(lost)])
        }
    }

    // MARK: - Commands

    func start(tenantID: UUID, request: HermesRunStartRequest, sessionKey: String?) async throws -> HermesRunDTO {
        let prompt = request.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { throw HermesRunsServiceError.emptyPrompt }
        if let conversationID = request.conversationID {
            guard try await Conversation.query(on: store.fluent.db(), tenantID: tenantID).filter(\.$id == conversationID).first() != nil else {
                throw HermesRunsServiceError.conversationNotFound
            }
        }
        try enforceLimits(tenantID: tenantID)

        let resolution = try await resolve(tenantID)
        let client = makeClient(resolution, sessionKey)
        try await requireRunsSupport(client: client)
        // Limits again: the capability probe suspended the actor.
        try enforceLimits(tenantID: tenantID)

        let hermesRunID = try await client.start(prompt: prompt, sessionID: request.sessionID, model: request.model)
        let run = HermesRun(
            tenantID: tenantID,
            hermesRunID: hermesRunID,
            status: .running,
            prompt: prompt,
            sessionID: request.sessionID,
            model: request.model,
            conversationID: request.conversationID,
            startedAt: store.now()
        )
        try await run.save(on: store.fluent.db())
        let runID = try run.requireID()
        if let conversationID = request.conversationID {
            try await appendConversationMarker(conversationID: conversationID, runID: runID, prompt: prompt)
        }
        try spawnWatcher(for: run, client: client, mode: .stream)
        store.publish(run: run, seq: 0, event: "run.accepted")
        return try run.toDTO()
    }

    func approve(tenantID: UUID, runID: UUID, choice: HermesApprovalChoice) async throws -> HermesRunDTO {
        guard let run = try await store.find(tenantID: tenantID, runID: runID) else { throw HermesRunsServiceError.runNotFound }
        guard run.pendingApproval != nil, !run.runStatus.isTerminal else { throw HermesRunsServiceError.approvalNotPending }
        let client = try await makeClient(resolve(tenantID), nil)
        do {
            try await client.approve(runID: run.hermesRunID, choice: choice)
        } catch HermesRunsClientError.approvalNotPending {
            // Hermes already moved on (approval answered elsewhere) — mirror it.
            try await store.clearPendingApproval(runID: runID)
            throw HermesRunsServiceError.approvalNotPending
        }
        try await store.clearPendingApproval(runID: runID)
        guard let updated = try await store.find(tenantID: tenantID, runID: runID) else { throw HermesRunsServiceError.runNotFound }
        store.publish(run: updated, seq: updated.lastSeq, event: "approval.sent")
        return try updated.toDTO()
    }

    func stop(tenantID: UUID, runID: UUID) async throws -> HermesRunDTO {
        guard let run = try await store.find(tenantID: tenantID, runID: runID) else { throw HermesRunsServiceError.runNotFound }
        if run.runStatus.isTerminal {
            return try run.toDTO()
        }
        let client = try await makeClient(resolve(tenantID), nil)
        do {
            try await client.stop(runID: run.hermesRunID)
        } catch HermesRunsClientError.runNotFound {
            // Hermes forgot it; nothing to wait for.
            cancelWatcher(runID: runID)
            let finished = try await store.finish(runID: runID, status: .stopped, error: nil)
            guard let finished else { throw HermesRunsServiceError.runNotFound }
            try await notifier.runFinished(tenantID: tenantID, run: finished.toDTO())
            return try finished.toDTO()
        }
        // `run.cancelled` arrives on the watcher; the DTO reflects it then.
        guard let current = try await store.find(tenantID: tenantID, runID: runID) else { throw HermesRunsServiceError.runNotFound }
        return try current.toDTO()
    }

    // MARK: - Queries

    func list(tenantID: UUID, limit: Int) async throws -> [HermesRunDTO] {
        try await store.list(tenantID: tenantID, limit: max(1, min(limit, 50))).map { try $0.toDTO() }
    }

    func get(tenantID: UUID, runID: UUID) async throws -> HermesRunDTO {
        guard let run = try await store.find(tenantID: tenantID, runID: runID) else { throw HermesRunsServiceError.runNotFound }
        return try run.toDTO()
    }

    /// Persisted events with `seq > afterSeq`, oldest first.
    func events(tenantID: UUID, runID: UUID, afterSeq: Int, limit: Int = 500) async throws -> [HermesRunEventDTO] {
        guard try await store.find(tenantID: tenantID, runID: runID) != nil else { throw HermesRunsServiceError.runNotFound }
        return try await store.events(runID: runID, afterSeq: afterSeq, limit: limit).map { $0.toDTO() }
    }

    // MARK: - Watcher bookkeeping

    var activeWatcherCount: Int {
        watchers.count
    }

    func activeWatcherCount(tenantID: UUID) -> Int {
        watchers.values.filter { $0.tenantID == tenantID }.count
    }

    func isWatching(runID: UUID) -> Bool {
        watchers[runID] != nil
    }

    /// Test hook: suspend until the watcher for `runID` has exited.
    func awaitWatcher(runID: UUID) async {
        guard let handle = watchers[runID] else { return }
        await handle.task.value
    }

    private func enforceLimits(tenantID: UUID) throws {
        guard watchers.count < limits.maxWatchersPerProcess,
              activeWatcherCount(tenantID: tenantID) < limits.maxWatchersPerTenant
        else { throw HermesRunsServiceError.tooManyActiveRuns }
    }

    private func requireRunsSupport(client: HermesRunsClient) async throws {
        let key = client.baseURL.absoluteString
        let now = store.now()
        if let cached = capabilityCache[key], now.timeIntervalSince(cached.checkedAt) < limits.capabilityCacheTTL {
            guard cached.supportsRuns else { throw HermesRunsClientError.unsupported }
            return
        }
        let supported = try await client.capabilities().supportsRuns
        capabilityCache[key] = CachedCapability(supportsRuns: supported, checkedAt: now)
        guard supported else { throw HermesRunsClientError.unsupported }
    }

    private func spawnWatcher(for run: HermesRun, client: HermesRunsClient, mode: HermesRunWatcher.Mode) throws {
        let runID = try run.requireID()
        let watcher = try HermesRunWatcher(
            run: run,
            mode: mode,
            client: client,
            store: store,
            notifier: notifier,
            config: limits.watcher,
            logger: logger
        )
        let task = Task { [weak self] in
            await watcher.run()
            await self?.watcherFinished(runID: runID)
        }
        watchers[runID] = WatcherHandle(tenantID: run.tenantID, task: task)
    }

    private func watcherFinished(runID: UUID) {
        watchers[runID] = nil
    }

    private func cancelWatcher(runID: UUID) {
        watchers.removeValue(forKey: runID)?.task.cancel()
    }

    private func markLost(_ run: HermesRun, reason: String) async {
        guard let id = run.id else { return }
        do {
            if let finished = try await store.finish(runID: id, status: .lost, error: reason) {
                try await notifier.runFinished(tenantID: run.tenantID, run: finished.toDTO())
            }
        } catch {
            logger.error("hermes run mark-lost failed", metadata: [
                "run": .string(id.uuidString),
                "error": .string(Logger.redact(String(describing: error))),
            ])
        }
    }

    /// Chat integration: a system turn in the conversation transcript that
    /// links to the run. The existing chat streaming path is untouched.
    private func appendConversationMarker(conversationID: UUID, runID: UUID, prompt: String) async throws {
        let message = ConversationMessage(
            conversationID: conversationID,
            role: .system,
            content: Self.conversationMarker(runID: runID, prompt: prompt)
        )
        try await message.save(on: store.fluent.db())
    }

    static func conversationMarker(runID: UUID, prompt: String) -> String {
        "Hermes run started: \(prompt)\nlumina://hermes/runs/\(runID.uuidString)"
    }
}
