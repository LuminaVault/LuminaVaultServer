@testable import App
import Foundation
import Testing

/// HER-200 L1 — message-level validation for the WebSocket broadcast path.
struct WebSocketBroadcastGuardTests {
    @Test
    func `valid JSON with type field is allowed`() {
        let decision = WebSocketBroadcastGuard.evaluate(#"{"type":"presence","userId":"abc"}"#)
        #expect(decision == .allow)
    }

    @Test
    func `empty string is rejected`() {
        #expect(WebSocketBroadcastGuard.evaluate("") == .rejectEmpty)
    }

    @Test
    func `oversize message is rejected`() {
        let oversize = String(repeating: "a", count: WebSocketBroadcastGuard.maxMessageBytes + 1)
        let decision = WebSocketBroadcastGuard.evaluate(oversize)
        #expect(decision == .rejectOversize(byteCount: WebSocketBroadcastGuard.maxMessageBytes + 1))
    }

    @Test
    func `message at exact size cap is allowed if JSON is valid`() {
        let typeKey = #"{"type":"x","pad":""#
        let suffix = #""}"#
        let padLen = WebSocketBroadcastGuard.maxMessageBytes - typeKey.count - suffix.count
        let pad = String(repeating: "a", count: padLen)
        let payload = typeKey + pad + suffix
        #expect(payload.utf8.count == WebSocketBroadcastGuard.maxMessageBytes)
        #expect(WebSocketBroadcastGuard.evaluate(payload) == .allow)
    }

    @Test
    func `plain text is rejected as invalid JSON`() {
        #expect(WebSocketBroadcastGuard.evaluate("hello world") == .rejectInvalidJSON)
    }

    @Test
    func `JSON array at top level is rejected`() {
        #expect(WebSocketBroadcastGuard.evaluate(#"[1,2,3]"#) == .rejectInvalidJSON)
    }

    @Test
    func `JSON object missing type field is rejected`() {
        #expect(WebSocketBroadcastGuard.evaluate(#"{"foo":"bar"}"#) == .rejectMissingType)
    }

    @Test
    func `JSON object with non-string type is rejected`() {
        #expect(WebSocketBroadcastGuard.evaluate(#"{"type":42}"#) == .rejectMissingType)
        #expect(WebSocketBroadcastGuard.evaluate(#"{"type":null}"#) == .rejectMissingType)
    }

    @Test
    func `extra fields are tolerated`() {
        let payload = #"{"type":"chat","sender":"alice","body":"hi","ts":1700000000}"#
        #expect(WebSocketBroadcastGuard.evaluate(payload) == .allow)
    }
}
