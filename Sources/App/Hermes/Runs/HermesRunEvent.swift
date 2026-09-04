import Foundation
import LuminaVaultShared

/// Typed view of one Hermes run event (`GET /v1/runs/{id}/events`).
/// Names follow `api_server.py` (`_handle_runs`, `_make_run_event_callback`,
/// `_approval_notify`). Anything unrecognised is kept as `.unknown` so the
/// full stream still persists and replays.
enum HermesRunEvent: Sendable, Equatable {
    case runStarted
    case messageStarted
    case messageDelta(String)
    case toolStarted(tool: String?, preview: String?)
    case toolCompleted(tool: String?, durationSeconds: Double?, isError: Bool)
    case toolFailed(tool: String?, error: String?)
    /// `hermes.tool.progress` / `tool.progress` / `reasoning.available`.
    case toolProgress(tool: String?, text: String)
    case approvalRequest(command: String?, choices: [HermesApprovalChoice], extra: [String: AnyJSONValue])
    case approvalResponded(choice: String?)
    case runCompleted(summary: String?)
    case runFailed(error: String)
    case runCancelled
    case error(message: String)
    case unknown(name: String, payload: AnyJSONValue)

    /// Status the run is in once this event has been applied; nil when the
    /// event carries no status change on its own.
    var impliedStatus: HermesRunStatus? {
        switch self {
        case .runStarted, .messageStarted, .messageDelta, .toolStarted, .toolCompleted, .toolFailed, .toolProgress,
             .approvalResponded:
            .running
        case .approvalRequest: .waitingForApproval
        case .runCompleted: .completed
        case .runFailed, .error: .failed
        case .runCancelled: .stopped
        case .unknown: nil
        }
    }

    var isTerminal: Bool {
        impliedStatus?.isTerminal ?? false
    }

    /// Build from a Hermes SSE record. The event name comes from the JSON
    /// `event` field, falling back to the SSE `event:` line.
    static func decode(eventName: String?, data: String) -> HermesRunEventFrame? {
        guard let raw = data.data(using: .utf8),
              let payload = try? JSONDecoder().decode(AnyJSONValue.self, from: raw)
        else { return nil }
        let object = payload.objectValue ?? [:]
        guard let name = object["event"]?.stringValue ?? eventName, !name.isEmpty else { return nil }
        let timestamp = object["timestamp"]?.doubleValue.map { Date(timeIntervalSince1970: $0) }
        return HermesRunEventFrame(
            name: name,
            event: parse(name: name, object: object, payload: payload),
            payload: payload,
            at: timestamp ?? Date()
        )
    }

    static func parse(name: String, object: [String: AnyJSONValue], payload: AnyJSONValue) -> HermesRunEvent {
        switch name {
        case "run.started": .runStarted
        case "message.started": .messageStarted
        case "message.delta", "assistant.delta": .messageDelta(object["delta"]?.stringValue ?? "")
        case "tool.started":
            .toolStarted(tool: object["tool"]?.stringValue ?? object["tool_name"]?.stringValue, preview: object["preview"]?.stringValue)
        case "tool.completed":
            .toolCompleted(
                tool: object["tool"]?.stringValue ?? object["tool_name"]?.stringValue,
                durationSeconds: object["duration"]?.doubleValue,
                isError: object["error"]?.boolValue ?? false
            )
        case "tool.failed":
            .toolFailed(
                tool: object["tool"]?.stringValue ?? object["tool_name"]?.stringValue,
                error: object["error"]?.stringValue ?? object["preview"]?.stringValue
            )
        case "hermes.tool.progress", "tool.progress", "reasoning.available":
            .toolProgress(
                tool: object["tool"]?.stringValue ?? object["tool_name"]?.stringValue,
                text: object["text"]?.stringValue ?? object["delta"]?.stringValue ?? object["preview"]?.stringValue ?? ""
            )
        case "approval.request":
            .approvalRequest(
                command: object["command"]?.stringValue,
                choices: parseChoices(object["choices"]),
                extra: object.filter { !["event", "run_id", "timestamp", "command", "choices"].contains($0.key) }
            )
        case "approval.responded": .approvalResponded(choice: object["choice"]?.stringValue)
        case "run.completed": .runCompleted(summary: object["output"]?.stringValue)
        case "run.failed": .runFailed(error: object["error"]?.stringValue ?? "agent run failed")
        case "run.cancelled": .runCancelled
        case "error": .error(message: object["message"]?.stringValue ?? object["error"]?.stringValue ?? "hermes error")
        default: .unknown(name: name, payload: payload)
        }
    }

    private static func parseChoices(_ value: AnyJSONValue?) -> [HermesApprovalChoice] {
        let parsed = (value?.arrayValue ?? []).compactMap(\.stringValue).compactMap(HermesApprovalChoice.init(rawValue:))
        return parsed.isEmpty ? HermesApprovalChoice.allCases : parsed
    }
}

/// One decoded stream record: the typed event plus the raw payload that
/// gets persisted and replayed verbatim.
struct HermesRunEventFrame: Sendable, Equatable {
    let name: String
    let event: HermesRunEvent
    let payload: AnyJSONValue
    let at: Date
}

extension AnyJSONValue {
    var stringValue: String? {
        if case let .string(value) = self {
            return value
        }
        return nil
    }

    var doubleValue: Double? {
        if case let .number(value) = self {
            return value
        }
        return nil
    }

    var boolValue: Bool? {
        if case let .bool(value) = self {
            return value
        }
        return nil
    }

    var objectValue: [String: AnyJSONValue]? {
        if case let .object(value) = self {
            return value
        }
        return nil
    }

    var arrayValue: [AnyJSONValue]? {
        if case let .array(value) = self {
            return value
        }
        return nil
    }
}
