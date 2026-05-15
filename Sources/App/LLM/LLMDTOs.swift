import Foundation
import Hummingbird
import LuminaVaultShared

extension ChatResponse: ResponseEncodable {}
extension TranscribeResponse: ResponseEncodable {}
extension VisionEmbedResponse: ResponseEncodable {}
extension MeTodayResponse: ResponseEncodable {}

// ─── Outbound wire format (used by adapters / transports only, NOT shared) ──

struct OutboundMessage: Encodable {
    let role: String
    let content: String?
    let tool_calls: [OutboundToolCall]?

    enum CodingKeys: String, CodingKey {
        case role, content, tool_calls
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
    let parameters: [String: AnyJSONValue]?
}

// ─── Server-side conversion helpers ─────────────────────────────────────────

extension ChatMessage {
    func toOutbound() -> OutboundMessage {
        let tc: [OutboundToolCall]? = tool_calls?.map { c in
            OutboundToolCall(
                id: c.id,
                type: c.type,
                function: OutboundToolCallFn(name: c.function.name, arguments: c.function.arguments),
            )
        }
        return OutboundMessage(
            role: role,
            content: content.isEmpty ? nil : content,
            tool_calls: tc,
        )
    }
}

extension ChatTool {
    func toOutbound() -> OutboundTool {
        OutboundTool(
            type: type,
            function: OutboundToolFunction(
                name: function.name,
                description: function.description,
                parameters: function.parameters,
            ),
        )
    }
}
