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
            await notifier.runFinished(tenantID: tenantID, run: dto)
        }
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
