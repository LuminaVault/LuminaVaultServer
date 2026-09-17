import Foundation
import Testing
@testable import App

@Suite("Client capability declaration")
struct ClientCapabilitiesTests {
    /// The one that matters. An old iOS build never sends this header, and
    /// its decoder dies on an unknown event type, so "no header" has to mean
    /// "send it nothing new". Failing open here would break chat for every
    /// shipped client the moment the server starts emitting a new event.
    @Test("An absent header supports nothing")
    func absentHeaderFailsClosed() {
        #expect(ClientCapabilities.parse(nil).supports(.chatHermesRun) == false)
    }

    @Test("An empty or whitespace header supports nothing")
    func emptyHeaderFailsClosed() {
        #expect(ClientCapabilities.parse("").supports(.chatHermesRun) == false)
        #expect(ClientCapabilities.parse("   ").supports(.chatHermesRun) == false)
        #expect(ClientCapabilities.parse(",,").supports(.chatHermesRun) == false)
    }

    @Test("A declared capability is recognised")
    func declaredCapabilityIsRecognised() {
        #expect(ClientCapabilities.parse("chat.hermes_run").supports(.chatHermesRun))
    }

    @Test("Order, spacing and case do not matter")
    func parsingIsForgiving() {
        let variants = [
            "chat.hermes_run",
            " chat.hermes_run ",
            "CHAT.HERMES_RUN",
            "something.else, chat.hermes_run",
            "chat.hermes_run,something.else",
        ]
        for value in variants {
            #expect(ClientCapabilities.parse(value).supports(.chatHermesRun), "failed for \(value)")
        }
    }

    /// Unknown tokens must be ignored rather than rejected, so a newer client
    /// can declare capabilities this server has never heard of without being
    /// downgraded on the ones it shares with us.
    @Test("Unknown tokens are ignored, not fatal")
    func unknownTokensAreIgnored() {
        let caps = ClientCapabilities.parse("chat.future_thing, chat.hermes_run, nonsense")
        #expect(caps.supports(.chatHermesRun))
    }

    @Test("A near-miss token does not count as the capability")
    func nearMissDoesNotCount() {
        #expect(ClientCapabilities.parse("chat.hermes").supports(.chatHermesRun) == false)
        #expect(ClientCapabilities.parse("chat.hermes_runs").supports(.chatHermesRun) == false)
        #expect(ClientCapabilities.parse("hermes_run").supports(.chatHermesRun) == false)
    }
}
