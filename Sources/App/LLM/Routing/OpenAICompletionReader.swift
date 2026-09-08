import Foundation

/// Shared reader for the parts of an OpenAI-compatible chat completion that
/// more than one caller needs.
///
/// Two callers want the same thing for different reasons, and duplicating the
/// parsing would let them drift:
///
/// - `ProviderToolProbe` asks *whether* the endpoint honours tools at all.
/// - `AgentTurnTrace` records *which* tools a real turn actually called.
///
/// They must agree on what counts as a tool call. If the probe recognised a
/// shape the trace did not, a provider would be advertised as tool-capable
/// while every one of its turns looked toolless to the user.
enum OpenAICompletionReader {
    /// The assistant message from the first choice, if the body is a
    /// well-formed completion.
    static func assistantMessage(from data: Data) -> [String: Any]? {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = root["choices"] as? [[String: Any]],
            let message = choices.first?["message"] as? [String: Any]
        else {
            return nil
        }
        return message
    }

    /// Names of the tools the model invoked, in call order.
    ///
    /// Empty means the turn ran without tools — a real answer, and distinct
    /// from the body being unreadable, which yields nil from
    /// `assistantMessage`.
    static func toolCallNames(in message: [String: Any]) -> [String] {
        if let toolCalls = message["tool_calls"] as? [[String: Any]] {
            let names = toolCalls.compactMap { call -> String? in
                guard let function = call["function"] as? [String: Any],
                      let name = function["name"] as? String,
                      !name.isEmpty
                else { return nil }
                return name
            }
            if !names.isEmpty {
                return names
            }
        }
        // Legacy single-function shape, still emitted by some gateways.
        if let functionCall = message["function_call"] as? [String: Any],
           let name = functionCall["name"] as? String,
           !name.isEmpty
        {
            return [name]
        }
        return []
    }

    /// Convenience for callers holding a raw response body.
    static func toolCallNames(from data: Data) -> [String] {
        guard let message = assistantMessage(from: data) else { return [] }
        return toolCallNames(in: message)
    }
}
