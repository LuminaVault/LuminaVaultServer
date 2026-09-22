@testable import App
import Foundation
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
}
