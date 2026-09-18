import FluentKit
import Foundation
import Logging
import LuminaVaultShared

/// Follows one Hermes run to its end. Owned by `HermesRunsService`, which
/// runs `run()` inside a tracked, cancellable task.
///
/// Two modes:
///   - `.stream` (fresh run): consume `GET /v1/runs/{id}/events`. Hermes
///     closes the stream after the terminal event.
///   - `.poll` (re-attach after a restart, or after the stream dropped
///     mid-run): Hermes tears the event queue down when a subscriber
///     disconnects, so a second `/events` call 404s. Poll `GET /v1/runs/{id}`
///     until the status is terminal and synthesise the status change as an
///     event so persistence, push and SSE fan-out stay uniform.
///
/// Every event is persisted with a monotonically increasing `seq` and the
/// run row is updated in the same step (`HermesRunStore.append`).
actor HermesRunWatcher {
    enum Mode: Sendable {
        case stream
        case poll
    }

    struct Config: Sendable {
        var pollInterval: Duration = .seconds(2)
        /// Hard stop for a run Hermes never finishes (hung tool, dead box).
        var maxRunLifetime: TimeInterval = 4 * 3600
    }

    let runID: UUID
    let tenantID: UUID
    private let hermesRunID: String
    private let startedAt: Date
    private let client: HermesRunsClient
    private let store: HermesRunStore
    private let notifier: any HermesRunPushNotifying
    private let config: Config
    private let logger: Logger
    private let mode: Mode
    private var status: HermesRunStatus
    private var hasPendingApproval: Bool

    init(
        run: HermesRun,
        mode: Mode,
        client: HermesRunsClient,
        store: HermesRunStore,
        notifier: any HermesRunPushNotifying,
        config: Config,
        logger: Logger
    ) throws {
        runID = try run.requireID()
        tenantID = run.tenantID
        hermesRunID = run.hermesRunID
        startedAt = run.startedAt
        status = run.runStatus
        hasPendingApproval = run.pendingApproval != nil
        self.mode = mode
        self.client = client
        self.store = store
        self.notifier = notifier
        self.config = config
        self.logger = logger
    }

    var currentStatus: HermesRunStatus {
        status
    }

    func run() async {
        if mode == .stream {
            do {
                try await consumeStream()
            } catch is CancellationError {
                return
            } catch {
                logger.warning("hermes run stream ended early; falling back to polling", metadata: [
                    "run": .string(runID.uuidString),
                    "error": .string(Logger.redact(String(describing: error))),
                ])
            }
        }
        if !status.isTerminal, !Task.isCancelled {
            await poll()
        }
    }

    // MARK: - Stream mode

    private func consumeStream() async throws {
        for try await frame in client.events(runID: hermesRunID) {
            try Task.checkCancellation()
            await apply(frame)
            if status.isTerminal {
                return
            }
        }
    }

    // MARK: - Poll mode

    private func poll() async {
        while !Task.isCancelled, !status.isTerminal {
            do {
                let snapshot = try await client.status(runID: hermesRunID)
                if let mapped = snapshot.mapped, mapped != status {
                    await apply(Self.synthesise(mapped, from: snapshot))
                }
            } catch HermesRunsClientError.runNotFound {
                await finish(.lost, error: "hermes no longer knows this run")
                return
            } catch is CancellationError {
                return
            } catch {
                logger.debug("hermes run poll failed", metadata: [
                    "run": .string(runID.uuidString),
                    "error": .string(Logger.redact(String(describing: error))),
                ])
            }
            if status.isTerminal {
                return
            }
            if store.now().timeIntervalSince(startedAt) > config.maxRunLifetime {
                await finish(.lost, error: "run exceeded the maximum lifetime")
                return
            }
            do {
                try await Task.sleep(for: config.pollInterval)
            } catch {
                return
            }
        }
    }

    /// A status change seen while polling, expressed as the event Hermes
    /// would have streamed for it.
    static func synthesise(_ status: HermesRunStatus, from snapshot: HermesRunStatusSnapshot) -> HermesRunEventFrame {
        let event: HermesRunEvent = switch status {
        case .waitingForApproval: .approvalRequest(command: nil, choices: HermesApprovalChoice.allCases, extra: [:])
        case .completed: .runCompleted(summary: snapshot.output)
        case .failed: .runFailed(error: snapshot.error ?? "agent run failed")
        case .stopped: .runCancelled
        case .running, .queued: .runStarted
        case .lost: .unknown(name: "watcher.lost", payload: .null)
        }
        let name = switch status {
        case .waitingForApproval: "approval.request"
        case .completed: "run.completed"
        case .failed: "run.failed"
        case .stopped: "run.cancelled"
        case .running, .queued: "run.started"
        case .lost: "watcher.lost"
        }
        var payload: [String: AnyJSONValue] = [
            "event": .string(name),
            "status": .string(snapshot.status),
            "source": .string("poll"),
        ]
        if let lastEvent = snapshot.lastEvent {
            payload["last_event"] = .string(lastEvent)
        }
        if let output = snapshot.output {
            payload["output"] = .string(output)
        }
        if let error = snapshot.error {
            payload["error"] = .string(error)
        }
        return HermesRunEventFrame(name: name, event: event, payload: .object(payload), at: Date())
    }

    // MARK: - Apply

    private func apply(_ frame: HermesRunEventFrame) async {
        let previous = status
        let next = Self.transition(from: previous, on: frame.event)
        let approvalWasPending = hasPendingApproval
        let at = frame.at
        let result: (seq: Int, run: HermesRun)?
        do {
            result = try await store.append(runID: runID, name: frame.name, payload: frame.payload, at: at) { run in
                switch frame.event {
                case let .approvalRequest(command, choices, extra):
                    run.pendingApproval = HermesRunPendingApprovalDTO(
                        command: command,
                        choices: choices,
                        requestedAt: at,
                        extra: extra.isEmpty ? nil : extra
                    )
                case let .runCompleted(summary):
                    run.summary = summary
                    run.pendingApproval = nil
                    run.finishedAt = at
                case let .runFailed(message), let .error(message):
                    run.error = message
                    run.pendingApproval = nil
                    run.finishedAt = at
                case .runCancelled:
                    run.pendingApproval = nil
                    run.finishedAt = at
                case .approvalResponded, .toolStarted, .toolCompleted, .toolFailed:
                    if next == .running {
                        run.pendingApproval = nil
                    }
                case .runStarted, .messageStarted, .messageDelta, .toolProgress, .unknown:
                    break
                }
                run.runStatus = next
            }
        } catch {
            logger.error("hermes run event persist failed", metadata: [
                "run": .string(runID.uuidString),
                "event": .string(frame.name),
                "error": .string(Logger.redact(String(describing: error))),
            ])
            return
        }
        guard let result else {
            // Row deleted under us (account deletion) — nothing left to track.
            status = .lost
            return
        }
        status = next
        hasPendingApproval = result.run.pendingApproval != nil
        guard let dto = try? result.run.toDTO() else { return }
        if case .approvalRequest = frame.event, !approvalWasPending {
            await notifier.approvalRequested(tenantID: tenantID, run: dto)
        }
        if next.isTerminal, !previous.isTerminal {
            await commitConversationTurn(run: result.run, at: at)
            await notifier.runFinished(tenantID: tenantID, run: dto)
        }
    }

    /// Writes the run's answer into the conversation as a real assistant turn.
    ///
    /// Until this exists, an escalated turn leaves only the system marker
    /// linking to the run — so the answer is on screen while the stream is
    /// live and gone the moment the thread is reopened, or opened on another
    /// device. The transcript has to be able to stand on its own.
    ///
    /// Idempotent on `hermes_run_id`, because this is not a
    /// once-per-run-ever code path: a watcher re-attaches to a non-terminal
    /// run after a restart and replays from its cursor, so a run that
    /// finished while the process was down reaches this line again. Writing
    /// twice would show the user the same answer twice.
    ///
    /// Never throws. A failure here must not stop the run from being marked
    /// finished or the push from going out — the answer is still readable on
    /// the run's own feed, which is a much smaller loss than a run stuck
    /// looking unfinished forever.
    /// Internal rather than private so the persistence tests can drive the
    /// idempotent path directly — replaying a terminal edge is exactly what a
    /// re-attached watcher does, and it is the case worth pinning.
    func commitConversationTurn(run: HermesRun, at _: Date) async {
        guard let conversationID = run.conversationID else { return }
        // A cancelled run has nothing to say. A failed one is reported
        // through the run's own status rather than as an assistant turn
        // claiming to be an answer.
        guard run.runStatus == .completed else { return }
        let summary = (run.summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else { return }

        do {
            let db = store.fluent.db()
            let existing = try await ConversationMessage.query(on: db)
                .filter(\.$hermesRunID == runID)
                .first()
            guard existing == nil else { return }

            let toolNames = try await store.events(runID: runID, afterSeq: 0, limit: 1000)
                .compactMap { HermesRunWatcher.toolName(inEventNamed: $0.event, payload: $0.payload) }

            let message = ConversationMessage(
                conversationID: conversationID,
                role: .assistant,
                content: summary
            )
            message.toolCallCount = toolNames.count
            message.hermesRunID = runID
            try await message.save(on: db)

            logger.info("hermes run answer committed to conversation", metadata: [
                "run": .string(runID.uuidString),
                "conversation": .string(conversationID.uuidString),
                "tools": .stringConvertible(toolNames.count),
            ])
        } catch {
            logger.error("hermes run conversation commit failed", metadata: [
                "run": .string(runID.uuidString),
                "error": .string(Logger.redact(String(describing: error))),
            ])
        }
    }

    /// The tool a `tool.started` event names, or nil for anything else.
    /// Counted rather than the completions, so a tool that never returned
    /// still shows as attempted.
    /// Payload is a dictionary rather than `AnyJSONValue` for the reason
    /// documented on `HermesRunEventRow.payload`: a bare `AnyJSONValue`
    /// Fluent field reads a `jsonb` column back as its text form.
    static func toolName(inEventNamed name: String, payload: [String: AnyJSONValue]) -> String? {
        guard name == "tool.started" else { return nil }
        for key in ["tool", "tool_name"] {
            if case let .string(value)? = payload[key], !value.isEmpty {
                return value
            }
        }
        return "tool"
    }

    /// State machine. A run waiting on approval only leaves that state on
    /// `approval.responded`, a tool event (the approved call executing) or a
    /// terminal event — stray deltas never hide a pending approval.
    static func transition(from current: HermesRunStatus, on event: HermesRunEvent) -> HermesRunStatus {
        if current.isTerminal {
            return current
        }
        guard let implied = event.impliedStatus else { return current }
        if implied.isTerminal || implied == .waitingForApproval {
            return implied
        }
        if current == .waitingForApproval {
            switch event {
            case .approvalResponded, .toolStarted, .toolCompleted, .toolFailed: return .running
            default: return current
            }
        }
        return .running
    }

    private func finish(_ terminal: HermesRunStatus, error: String?) async {
        let previous = status
        do {
            guard let run = try await store.finish(runID: runID, status: terminal, error: error) else {
                status = terminal
                return
            }
            status = terminal
            hasPendingApproval = false
            if !previous.isTerminal, let dto = try? run.toDTO() {
                await notifier.runFinished(tenantID: tenantID, run: dto)
            }
        } catch {
            logger.error("hermes run finish failed", metadata: [
                "run": .string(runID.uuidString),
                "status": .string(terminal.rawValue),
                "error": .string(Logger.redact(String(describing: error))),
            ])
            status = terminal
        }
    }
}
