@testable import App
import Foundation
import LuminaVaultShared
import Testing

/// The substitution rule on its own, without HTTP or a database.
///
/// `/v1/router` hides a managed profile's routes behind `openRouter/auto`. That
/// value is a mask, not a model: stored as a BYOK route it names nothing a
/// provider will serve. A BYOK save that carries it back gets the tenant's own
/// saved chain in its place, or nothing is saved at all.
struct RouterPlaceholderRoutesTests {
    private static let placeholder = RouterModelRouteDTO(
        provider: ManagedLLMDefaults.provider,
        model: ModelDisclosurePolicy.genericModelID
    )
    private static let opus = RouterModelRouteDTO(provider: .anthropic, model: "claude-opus-4-7")
    private static let mini = RouterModelRouteDTO(provider: .openai, model: "gpt-4o-mini")

    private static func request(
        mode: LLMBrainMode = .byok,
        defaultAction: RouterActionDTO,
        rules: [RouterRuleDTO] = []
    ) -> RouterProfileWriteRequest {
        RouterProfileWriteRequest(
            name: "Default",
            mode: mode,
            objective: .init(quality: 50, cost: 25, latency: 25),
            budget: .init(),
            defaultAction: defaultAction,
            rules: rules,
            routingPolicy: .balanced
        )
    }

    @Test
    func `the placeholder is recognised and a real openRouter model is not`() {
        #expect(ModelDisclosurePolicy.isPlaceholder(Self.placeholder))
        #expect(!ModelDisclosurePolicy.isPlaceholder(RouterModelRouteDTO(provider: .openRouter, model: ManagedLLMDefaults.model)))
        #expect(!ModelDisclosurePolicy.isPlaceholder(RouterModelRouteDTO(provider: .anthropic, model: "auto")))
    }

    @Test
    func `a placeholder route becomes the saved chain, in order`() throws {
        let resolved = try RouterPlaceholderRoutes.substitute(
            in: Self.request(defaultAction: RouterActionDTO(routes: [Self.placeholder])),
            chain: [Self.opus, Self.mini]
        )
        #expect(resolved.defaultAction.routes == [Self.opus, Self.mini])
    }

    @Test
    func `real routes around the placeholder stay, and duplicates collapse`() throws {
        let resolved = try RouterPlaceholderRoutes.substitute(
            in: Self.request(defaultAction: RouterActionDTO(routes: [Self.mini, Self.placeholder])),
            chain: [Self.opus, Self.mini]
        )
        #expect(resolved.defaultAction.routes == [Self.mini, Self.opus])
    }

    @Test
    func `rule actions and a placeholder synthesis route are resolved too`() throws {
        let rule = RouterRuleDTO(
            name: "reasoning",
            priority: 1,
            taskTypes: [.reasoning],
            action: RouterActionDTO(kind: .ensemble, routes: [Self.placeholder, Self.mini], synthesisRoute: Self.placeholder)
        )
        let resolved = try RouterPlaceholderRoutes.substitute(
            in: Self.request(defaultAction: RouterActionDTO(routes: [Self.mini]), rules: [rule]),
            chain: [Self.opus]
        )
        let action = try #require(resolved.rules.first?.action)
        #expect(action.routes == [Self.opus, Self.mini])
        // The synthesis step is one model, so it takes the chain's primary.
        #expect(action.synthesisRoute == Self.opus)
        #expect(resolved.rules.first?.id == rule.id)
    }

    @Test
    func `with nothing to substitute a placeholder is refused`() {
        #expect(throws: RouterProfileRepositoryError.placeholderRoute) {
            try RouterPlaceholderRoutes.substitute(
                in: Self.request(defaultAction: RouterActionDTO(routes: [Self.placeholder])),
                chain: []
            )
        }
    }

    @Test
    func `a request without the placeholder is returned untouched, chain or not`() throws {
        let request = Self.request(defaultAction: RouterActionDTO(routes: [Self.mini]))
        let resolved = try RouterPlaceholderRoutes.substitute(in: request, chain: [])
        #expect(resolved.defaultAction == request.defaultAction)
    }

    @Test
    func `a managed save is left alone, the managed document rewrites it anyway`() throws {
        let request = Self.request(mode: .managed, defaultAction: RouterActionDTO(routes: [Self.placeholder]))
        let resolved = try RouterPlaceholderRoutes.substitute(in: request, chain: [])
        #expect(resolved.defaultAction == request.defaultAction)
    }
}
