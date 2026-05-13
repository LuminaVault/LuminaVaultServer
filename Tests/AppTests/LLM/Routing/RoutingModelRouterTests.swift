import Testing
@testable import App

@Suite("RoutingModelRouterTests")
struct RoutingModelRouterTests {

    @Test("nil model defaults to hermesGateway")
    func picksHermesWhenModelIsNil() async {
        let router = RoutingModelRouter()
        let decision = await router.pick(forModel: nil, user: nil)
        #expect(decision.primary == .hermesGateway)
        #expect(decision.fallbacks.isEmpty)
    }

    @Test("empty model defaults to hermesGateway")
    func picksHermesWhenModelIsEmpty() async {
        let router = RoutingModelRouter()
        let decision = await router.pick(forModel: "", user: nil)
        #expect(decision.primary == .hermesGateway)
        #expect(decision.fallbacks.isEmpty)
    }

    @Test("gemini-2.5-pro routes to gemini")
    func routesToGeminiForGeminiPro() async {
        let router = RoutingModelRouter()
        let decision = await router.pick(forModel: "gemini-2.5-pro", user: nil)
        #expect(decision.primary == .gemini)
        #expect(decision.fallbacks == [.hermesGateway])
    }

    @Test("gemini-2.5-flash routes to gemini")
    func routesToGeminiForGeminiFlash() async {
        let router = RoutingModelRouter()
        let decision = await router.pick(forModel: "gemini-2.5-flash", user: nil)
        #expect(decision.primary == .gemini)
        #expect(decision.fallbacks == [.hermesGateway])
    }

    @Test("bare gemini keyword routes to gemini")
    func routesToGeminiForBareGemini() async {
        let router = RoutingModelRouter()
        let decision = await router.pick(forModel: "gemini", user: nil)
        #expect(decision.primary == .gemini)
    }

    @Test("case insensitive gemini routing")
    func routesToGeminiCaseInsensitive() async {
        let router = RoutingModelRouter()
        let decision = await router.pick(forModel: "GEMINI-2.5-PRO", user: nil)
        #expect(decision.primary == .gemini)
    }

    @Test("non-gemini model goes to hermesGateway")
    func routesToHermesForNonGeminiModel() async {
        let router = RoutingModelRouter()
        let decision = await router.pick(forModel: "gpt-4", user: nil)
        #expect(decision.primary == .hermesGateway)
        #expect(decision.fallbacks.isEmpty)
    }

    @Test("claude model goes to hermesGateway")
    func routesToHermesForClaudeModel() async {
        let router = RoutingModelRouter()
        let decision = await router.pick(forModel: "claude-sonnet-4", user: nil)
        #expect(decision.primary == .hermesGateway)
    }

    @Test("custom fallbacks are appended")
    func includesCustomFallbacks() async {
        let router = RoutingModelRouter(fallbacks: [.openRouter, .groq])
        let decision = await router.pick(forModel: "gemini-2.5-pro", user: nil)
        #expect(decision.primary == .gemini)
        #expect(decision.fallbacks == [.hermesGateway, .openRouter, .groq])
    }
}
