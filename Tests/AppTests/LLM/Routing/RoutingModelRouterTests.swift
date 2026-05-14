@testable import App
import Testing

@Suite("RoutingModelRouterTests")
struct RoutingModelRouterTests {
    @Test
    func `nil model defaults to hermesGateway`() async {
        let router = RoutingModelRouter()
        let decision = await router.pick(forModel: nil, capability: .medium, user: nil)
        #expect(decision.primary.provider == .hermesGateway)
        #expect(decision.fallbacks.isEmpty)
    }

    @Test
    func `empty model defaults to hermesGateway`() async {
        let router = RoutingModelRouter()
        let decision = await router.pick(forModel: "", capability: .medium, user: nil)
        #expect(decision.primary.provider == .hermesGateway)
        #expect(decision.fallbacks.isEmpty)
    }

    @Test
    func `gemini-2.5-pro routes to gemini`() async {
        let router = RoutingModelRouter()
        let decision = await router.pick(forModel: "gemini-2.5-pro", capability: .medium, user: nil)
        #expect(decision.primary.provider == .gemini)
        #expect(decision.fallbacks.map(\.provider) == [.hermesGateway])
    }

    @Test
    func `gemini-2.5-flash routes to gemini`() async {
        let router = RoutingModelRouter()
        let decision = await router.pick(forModel: "gemini-2.5-flash", capability: .medium, user: nil)
        #expect(decision.primary.provider == .gemini)
        #expect(decision.fallbacks.map(\.provider) == [.hermesGateway])
    }

    @Test
    func `bare gemini keyword routes to gemini`() async {
        let router = RoutingModelRouter()
        let decision = await router.pick(forModel: "gemini", capability: .medium, user: nil)
        #expect(decision.primary.provider == .gemini)
    }

    @Test
    func `case insensitive gemini routing`() async {
        let router = RoutingModelRouter()
        let decision = await router.pick(forModel: "GEMINI-2.5-PRO", capability: .medium, user: nil)
        #expect(decision.primary.provider == .gemini)
    }

    @Test
    func `non-gemini model goes to hermesGateway`() async {
        let router = RoutingModelRouter()
        let decision = await router.pick(forModel: "gpt-4", capability: .medium, user: nil)
        #expect(decision.primary.provider == .hermesGateway)
        #expect(decision.fallbacks.isEmpty)
    }

    @Test
    func `claude model goes to hermesGateway`() async {
        let router = RoutingModelRouter()
        let decision = await router.pick(forModel: "claude-sonnet-4", capability: .medium, user: nil)
        #expect(decision.primary.provider == .hermesGateway)
    }

    @Test
    func `custom fallbacks are appended`() async {
        let router = RoutingModelRouter(fallbacks: [.openRouter, .groq])
        let decision = await router.pick(forModel: "gemini-2.5-pro", capability: .medium, user: nil)
        #expect(decision.primary.provider == .gemini)
        #expect(decision.fallbacks.map(\.provider) == [.hermesGateway, .openRouter, .groq])
    }
}
