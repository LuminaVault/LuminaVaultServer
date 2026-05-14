@testable import App
import Testing

@Suite("RoutingModelRouterTests")
struct RoutingModelRouterTests {
    @Test
    func `nil model defaults to hermesGateway`() async {
        let router = RoutingModelRouter()
        let decision = await router.pick(forModel: nil, user: nil)
        #expect(decision.primary == .hermesGateway)
        #expect(decision.fallbacks.isEmpty)
    }

    @Test
    func `empty model defaults to hermesGateway`() async {
        let router = RoutingModelRouter()
        let decision = await router.pick(forModel: "", user: nil)
        #expect(decision.primary == .hermesGateway)
        #expect(decision.fallbacks.isEmpty)
    }

    @Test
    func `gemini-2.5-pro routes to gemini`() async {
        let router = RoutingModelRouter()
        let decision = await router.pick(forModel: "gemini-2.5-pro", user: nil)
        #expect(decision.primary == .gemini)
        #expect(decision.fallbacks == [.hermesGateway])
    }

    @Test
    func `gemini-2.5-flash routes to gemini`() async {
        let router = RoutingModelRouter()
        let decision = await router.pick(forModel: "gemini-2.5-flash", user: nil)
        #expect(decision.primary == .gemini)
        #expect(decision.fallbacks == [.hermesGateway])
    }

    @Test
    func `bare gemini keyword routes to gemini`() async {
        let router = RoutingModelRouter()
        let decision = await router.pick(forModel: "gemini", user: nil)
        #expect(decision.primary == .gemini)
    }

    @Test
    func `case insensitive gemini routing`() async {
        let router = RoutingModelRouter()
        let decision = await router.pick(forModel: "GEMINI-2.5-PRO", user: nil)
        #expect(decision.primary == .gemini)
    }

    @Test
    func `non-gemini model goes to hermesGateway`() async {
        let router = RoutingModelRouter()
        let decision = await router.pick(forModel: "gpt-4", user: nil)
        #expect(decision.primary == .hermesGateway)
        #expect(decision.fallbacks.isEmpty)
    }

    @Test
    func `claude model goes to hermesGateway`() async {
        let router = RoutingModelRouter()
        let decision = await router.pick(forModel: "claude-sonnet-4", user: nil)
        #expect(decision.primary == .hermesGateway)
    }

    @Test
    func `custom fallbacks are appended`() async {
        let router = RoutingModelRouter(fallbacks: [.openRouter, .groq])
        let decision = await router.pick(forModel: "gemini-2.5-pro", user: nil)
        #expect(decision.primary == .gemini)
        #expect(decision.fallbacks == [.hermesGateway, .openRouter, .groq])
    }
}
