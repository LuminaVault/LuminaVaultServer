@testable import App
import Foundation
import Hummingbird
import Testing

struct UpstreamErrorResponseTests {
    @Test
    func `timeout code maps to 504 Gateway Timeout`() {
        let err = UpstreamErrorResponse(reasonCode: "upstream_timeout", userMessage: "Hermes timed out.")
        #expect(err.status == .gatewayTimeout)
    }

    @Test
    func `unreachable code maps to 502 Bad Gateway`() {
        let err = UpstreamErrorResponse(reasonCode: "upstream_unreachable", userMessage: "Couldn't reach Hermes.")
        #expect(err.status == .badGateway)
    }

    @Test
    func `generic network code maps to 502 Bad Gateway`() {
        let err = UpstreamErrorResponse(reasonCode: "network", userMessage: "x")
        #expect(err.status == .badGateway)
    }

    @Test
    func `upstream_rejected maps to 502 Bad Gateway`() {
        let err = UpstreamErrorResponse(reasonCode: "upstream_rejected", userMessage: "x")
        #expect(err.status == .badGateway)
    }

    @Test
    func `body serializes to error envelope JSON`() throws {
        let err = UpstreamErrorResponse(
            reasonCode: "upstream_timeout",
            userMessage: "Hermes timed out.",
            retryAfterMs: 2000,
        )
        let json = try JSONSerialization.jsonObject(with: err.bodyData) as? [String: Any]
        let outer = try #require(json?["error"] as? [String: Any])
        #expect(outer["code"] as? String == "upstream_timeout")
        #expect(outer["message"] as? String == "Hermes timed out.")
        #expect(outer["retry_after_ms"] as? Int == 2000)
    }

    @Test
    func `retry_after_ms omitted when nil`() throws {
        let err = UpstreamErrorResponse(reasonCode: "network", userMessage: "x")
        let json = try JSONSerialization.jsonObject(with: err.bodyData) as? [String: Any]
        let outer = try #require(json?["error"] as? [String: Any])
        #expect(outer["retry_after_ms"] == nil)
    }
}
