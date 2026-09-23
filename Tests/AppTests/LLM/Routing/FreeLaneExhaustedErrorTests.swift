@testable import App
import Foundation
import Testing

/// What an exhausted free lane tells the user depends on who they are.
///
/// It used to offer `upgrade` to everyone. A paying user reaches the lane only
/// by choosing BYOK without a key, or when the platform is down; telling them
/// to "upgrade for the full brain" names something they already have.
struct FreeLaneExhaustedErrorTests {
    private static func body(_ error: FreeLaneExhaustedError) throws -> [String: Any] {
        let json = try #require(JSONSerialization.jsonObject(with: error.bodyData) as? [String: Any])
        return try #require(json["error"] as? [String: Any])
    }

    @Test
    func `an unpaid user is offered an upgrade or a key`() throws {
        let error = FreeLaneExhaustedError(retryAfterSeconds: 60, actions: ["upgrade", "add_key"])
        #expect(try Self.body(error)["cta"] as? [String] == ["upgrade", "add_key"])
        #expect(error.userMessage.contains("Upgrade"))
    }

    @Test
    func `a paying byok user is offered managed or a key, never an upgrade`() throws {
        let error = FreeLaneExhaustedError(retryAfterSeconds: 60, actions: ["add_key", "switch_to_managed"])
        #expect(try Self.body(error)["cta"] as? [String] == ["add_key", "switch_to_managed"])
        #expect(!error.userMessage.contains("Upgrade"))
        #expect(error.userMessage.contains("Managed"))
    }

    @Test
    func `a paying user in an outage is offered a key only`() throws {
        let error = FreeLaneExhaustedError(retryAfterSeconds: 60, actions: ["add_key"])
        #expect(try Self.body(error)["cta"] as? [String] == ["add_key"])
        #expect(!error.userMessage.contains("Upgrade"))
        #expect(!error.userMessage.contains("Managed"))
    }

    @Test
    func `the retry hint is unchanged`() throws {
        let error = FreeLaneExhaustedError(retryAfterSeconds: 60, actions: ["add_key"])
        #expect(try Self.body(error)["retryAfterSeconds"] as? Int == 60)
        #expect(try Self.body(error)["code"] as? String == "free_lane_exhausted")
    }
}
