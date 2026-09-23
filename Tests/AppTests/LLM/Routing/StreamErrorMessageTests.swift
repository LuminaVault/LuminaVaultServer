@testable import App
import Foundation
import LuminaVaultShared
import Testing

/// Which errors a stream may explain to the user, and which it must not.
struct StreamErrorMessageTests {
    @Test
    func `routing and allowance errors carry their own message`() {
        #expect(StreamErrorMessage.forClient(BYOKKeysRequiredError()) == BYOKKeysRequiredError().userMessage)
        let lane = FreeLaneExhaustedError(retryAfterSeconds: 60)
        #expect(StreamErrorMessage.forClient(lane) == lane.userMessage)
        let cap = UsageCapExceededError(retryAfter: 60)
        #expect(StreamErrorMessage.forClient(cap) == cap.userMessage)
        let upstream = UpstreamErrorResponse(reasonCode: "credit_exhausted", userMessage: "Your provider is out of credit.")
        #expect(StreamErrorMessage.forClient(upstream) == "Your provider is out of credit.")
    }

    /// An internal failure's description can hold SQL, paths or provider
    /// payloads, so it must never become the client-visible message.
    @Test
    func `anything else stays generic`() {
        struct Internal: Error, CustomStringConvertible {
            var description: String {
                "PSQLError: relation \"users\" does not exist"
            }
        }
        #expect(StreamErrorMessage.forClient(Internal()) == StreamErrorMessage.generic)
        #expect(StreamErrorMessage.forClient(CancellationError()) == StreamErrorMessage.generic)
    }

    /// A refusal the user can act on ends the stream with its code and the
    /// same recovery actions its HTTP envelope carries.
    @Test
    func `an actionable error becomes a detailed error event`() {
        let lane = FreeLaneExhaustedError(retryAfterSeconds: 60, actions: ["add_key", "switch_to_managed"])
        #expect(StreamErrorMessage.event(for: lane) == .errorDetail(StreamErrorDTO(
            message: lane.userMessage,
            code: "free_lane_exhausted",
            cta: ["add_key", "switch_to_managed"]
        )))
        #expect(StreamErrorMessage.event(for: BYOKKeysRequiredError()) == .errorDetail(StreamErrorDTO(
            message: BYOKKeysRequiredError().userMessage,
            code: "byok_keys_required",
            cta: ["add_key", "switch_to_managed"]
        )))
        #expect(StreamErrorMessage.event(for: UsageCapExceededError(retryAfter: 60)).errorMessage
            == UsageCapExceededError(retryAfter: 60).userMessage)
    }

    /// An internal failure stays a plain, generic error: no code, no detail,
    /// and nothing from its description.
    @Test
    func `an internal error stays a plain generic event`() {
        struct Internal: Error, CustomStringConvertible {
            var description: String {
                "PSQLError: relation \"users\" does not exist"
            }
        }
        #expect(StreamErrorMessage.event(for: Internal()) == .error(StreamErrorMessage.generic))
    }
}
