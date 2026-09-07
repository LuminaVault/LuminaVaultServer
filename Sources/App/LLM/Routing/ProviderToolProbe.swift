import Foundation
import Logging

/// Does this endpoint actually honour tool calls?
///
/// A credential that authenticates is not the same as an endpoint that works.
/// An OpenAI-compatible gateway can accept a request carrying `tools`, ignore
/// the block entirely, and answer from the model's own knowledge. The reply is
/// a well-formed 200 with plausible content, so nothing upstream notices — and
/// the product then tells the user their skills and workflows are running when
/// the model never called a single tool.
///
/// The probe asks something that cannot be answered from training data and
/// binds exactly one tool that would answer it. A backend that honours tools
/// emits a tool call; one that does not answers in prose, confidently and
/// wrongly. That difference is the whole signal.
enum ProviderToolProbe {
    /// Three-valued by necessity.
    enum Verdict: Sendable, Equatable {
        case supported
        case notSupported
        /// The probe could not reach a conclusion — network failure, an
        /// unexpected body shape, a model that refused. Read as permissive.
        case unknown
    }

    /// A token no model can know, so the only way to answer is to call the
    /// tool. Regenerated per probe so a cached completion upstream cannot
    /// satisfy it.
    static func nonce() -> String {
        "lv-" + UUID().uuidString.prefix(8).lowercased()
    }

    /// The probe request body. One tool, one question that requires it, and a
    /// tight token budget — this runs against the user's own key and must
    /// cost them as close to nothing as possible.
    static func payload(model: String, nonce: String) -> [String: Any] {
        [
            "model": model,
            "max_tokens": 64,
            "messages": [[
                "role": "user",
                "content": "What is the status of job \(nonce)? Use the tool; do not guess.",
            ]],
            "tools": [[
                "type": "function",
                "function": [
                    "name": "lookup_job_status",
                    "description": "Look up the status of a job by its opaque identifier.",
                    "parameters": [
                        "type": "object",
                        "properties": ["id": ["type": "string"]],
                        "required": ["id"],
                    ],
                ],
            ]],
            "tool_choice": "auto",
        ]
    }

    /// Reads a verdict out of an OpenAI-compatible chat completion.
    ///
    /// Only an actual tool call counts as support. Prose that *mentions* the
    /// tool does not: a model narrating "I would call lookup_job_status" is
    /// precisely the failure being detected.
    static func verdict(from data: Data) -> Verdict {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = root["choices"] as? [[String: Any]],
            let message = choices.first?["message"] as? [String: Any]
        else {
            return .unknown
        }
        if let toolCalls = message["tool_calls"] as? [[String: Any]], !toolCalls.isEmpty {
            return .supported
        }
        // Legacy single-function shape, still emitted by some gateways.
        if let functionCall = message["function_call"] as? [String: Any], functionCall["name"] != nil {
            return .supported
        }
        // A reply with neither a tool call nor content tells us nothing; a
        // reply with prose content is the endpoint answering without tools.
        if let content = message["content"] as? String, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .notSupported
        }
        return .unknown
    }

    /// Whether a stored verdict should permit tool-dependent features.
    ///
    /// `nil` — not probed, or no verdict — is permissive on purpose. The probe
    /// is a best-effort background check against a third party; treating "we
    /// do not know" as "no tools" would disable working setups on a network
    /// blip, which is a worse failure than the one being detected.
    static func allowsTools(storedVerdict: Bool?) -> Bool {
        storedVerdict ?? true
    }
}
