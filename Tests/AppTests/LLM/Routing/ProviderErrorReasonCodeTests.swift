@testable import App
import Foundation
import Testing

struct ProviderErrorReasonCodeTests {
    @Test
    func `timeout URLError maps to upstream_timeout reason code`() {
        let err = ProviderError.network(provider: .hermesGateway, underlying: URLError(.timedOut))
        #expect(err.reasonCode == "upstream_timeout")
        #expect(err.userMessage == "Hermes timed out responding.")
    }

    @Test
    func `cannotConnectToHost URLError maps to upstream_unreachable`() {
        let err = ProviderError.network(provider: .hermesGateway, underlying: URLError(.cannotConnectToHost))
        #expect(err.reasonCode == "upstream_unreachable")
        #expect(err.userMessage == "Couldn't reach Hermes.")
    }

    @Test
    func `notConnectedToInternet URLError maps to upstream_unreachable`() {
        let err = ProviderError.network(provider: .hermesGateway, underlying: URLError(.notConnectedToInternet))
        #expect(err.reasonCode == "upstream_unreachable")
        #expect(err.userMessage == "Couldn't reach Hermes.")
    }

    @Test
    func `unknown URLError falls through to generic network code`() {
        let err = ProviderError.network(provider: .hermesGateway, underlying: URLError(.unknown))
        #expect(err.reasonCode == "network")
        #expect(err.userMessage == "Couldn't reach Hermes.")
    }

    @Test
    func `non-URLError underlying falls through to generic network code`() {
        struct SomeOtherError: Error {}
        let err = ProviderError.network(provider: .hermesGateway, underlying: SomeOtherError())
        #expect(err.reasonCode == "network")
        #expect(err.userMessage == "Couldn't reach Hermes.")
    }

    @Test
    func `cannotFindHost URLError maps to upstream_unreachable`() {
        let err = ProviderError.network(provider: .hermesGateway, underlying: URLError(.cannotFindHost))
        #expect(err.reasonCode == "upstream_unreachable")
        #expect(err.userMessage == "Couldn't reach Hermes.")
    }

    @Test
    func `dnsLookupFailed URLError maps to upstream_unreachable`() {
        let err = ProviderError.network(provider: .hermesGateway, underlying: URLError(.dnsLookupFailed))
        #expect(err.reasonCode == "upstream_unreachable")
        #expect(err.userMessage == "Couldn't reach Hermes.")
    }

    @Test
    func `networkConnectionLost URLError maps to upstream_unreachable`() {
        let err = ProviderError.network(provider: .hermesGateway, underlying: URLError(.networkConnectionLost))
        #expect(err.reasonCode == "upstream_unreachable")
        #expect(err.userMessage == "Couldn't reach Hermes.")
    }
}
