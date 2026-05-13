import Foundation
import Hummingbird

// ─── Utility types ─────────────────────────────────────────────────────────

/// JSON value enum — supports any JSON type while staying fully Codable.
enum AnyJSONValue: Codable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case object([String: AnyJSONValue])
    case array([AnyJSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(String.self) { self = .string(v)
        } else if let v = try? c.decode(Double.self) { self = .number(v)
        } else if let v = try? c.decode(Bool.self) { self = .bool(v)
        } else if let v = try? c.decode([String: AnyJSONValue].self) { self = .object(v)
        } else if let v = try? c.decode([AnyJSONValue].self) { self = .array(v)
        } else if c.decodeNil() { self = .null
        } else { self = .string("") }
    }
}

typealias AnyCodableDict = [String: AnyJSONValue]

// ─── Core DTOs ─────────────────────────────────────────────────────────────

struct ChatMessage: Codable, Sendable {
    let role: String
    let content: String
    let tool_calls: [ChatToolCall]?

    enum CodingKeys: String, CodingKey {
        case role, content
        case tool_calls
    }
}

struct ChatToolCall: Codable, Sendable {
    let id: String
    let type: String
    let function: ChatToolCallFunction
}

struct ChatToolCallFunction: Codable, Sendable {
    let name: String
    let arguments: String
}

struct ChatTool: Codable, Sendable {
    let type: String
    let function: ChatToolDefinition
}

struct ChatToolDefinition: Codable, Sendable {
    let name: String
    let description: String?
    let parameters: AnyCodableDict?
}

struct ChatRequest: Codable, Sendable {
    let messages: [ChatMessage]
    let model: String?
    let temperature: Double?
    let stream: Bool
    let tools: [ChatTool]?
    let tool_choice: AnyJSONValue?

    enum CodingKeys: String, CodingKey {
        case messages, model, temperature, stream, tools
        case tool_choice
    }
}

// ─── Outbound wire format (used by adapters / transports) ──────────────────

struct OutboundMessage: Encodable {
    let role: String
    let content: String?
    let tool_calls: [OutboundToolCall]?

    enum CodingKeys: String, CodingKey {
        case role, content
        case tool_calls
    }
}

struct OutboundToolCall: Encodable {
    let id: String
    let type: String
    let function: OutboundToolCallFn
}

struct OutboundToolCallFn: Encodable {
    let name: String
    let arguments: String
}

struct OutboundTool: Encodable {
    let type: String
    let function: OutboundToolFunction

    enum CodingKeys: String, CodingKey {
        case type, function
    }
}

struct OutboundToolFunction: Encodable {
    let name: String
    let description: String?
    let parameters: AnyCodableDict?
}

// ─── Response DTOs ─────────────────────────────────────────────────────────

struct HermesUpstreamChoice: Codable {
    let index: Int?
    let message: ChatMessage
    let finishReason: String?

    enum CodingKeys: String, CodingKey {
        case index
        case message
        case finishReason = "finish_reason"
    }
}

struct HermesUpstreamUsage: Codable {
    let promptTokens: Int?
    let completionTokens: Int?
    let totalTokens: Int?

    enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case totalTokens = "total_tokens"
    }
}

struct HermesUpstreamResponse: Codable {
    let id: String
    let object: String?
    let created: Int?
    let model: String
    let choices: [HermesUpstreamChoice]
    let usage: HermesUpstreamUsage?
}

struct ChatResponse: Codable, ResponseEncodable {
    let id: String
    let model: String
    let message: ChatMessage
    let raw: HermesUpstreamResponse
}

// ─── Inbound → Outbound conversion ─────────────────────────────────────────

extension ChatMessage {
    func toOutbound() -> OutboundMessage {
        let tc: [OutboundToolCall]? = tool_calls?.map { c in
            OutboundToolCall(
                id: c.id,
                type: c.type,
                function: OutboundToolCallFn(name: c.function.name, arguments: c.function.arguments))
        }
        return OutboundMessage(
            role: role,
            content: content.isEmpty ? nil : content,
            tool_calls: tc)
    }
}

extension ChatTool {
    func toOutbound() -> OutboundTool {
        return OutboundTool(
            type: type,
            function: OutboundToolFunction(
                name: function.name,
                description: function.description,
                parameters: function.parameters))
    }
}
