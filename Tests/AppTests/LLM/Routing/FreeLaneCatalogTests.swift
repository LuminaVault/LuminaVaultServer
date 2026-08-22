@testable import App
import LuminaVaultShared
import Testing

/// Invariants the free lane cannot survive losing. All pure.
struct FreeLaneCatalogTests {
    @Test("both legs are present, OpenRouter first")
    func legOrder() {
        let routes = FreeLaneCatalog.routes()
        #expect(routes.map(\.leg) == [.openRouterFree, .nvidiaDirect])
        #expect(routes[0].provider == .openRouter)
        #expect(routes[1].provider == .nvidia)
    }

    @Test("preferring a leg promotes it without dropping the other")
    func preferringPromotes() {
        let routes = FreeLaneCatalog.routes(preferring: .nvidiaDirect)
        #expect(routes.map(\.leg) == [.nvidiaDirect, .openRouterFree])
        #expect(routes.count == FreeLaneCatalog.Leg.allCases.count)
    }

    /// Hermes Agent refuses to start a turn below 64K and fails the whole
    /// request, so a free slug that drops under it takes chat down for every
    /// non-paying user at once.
    @Test("every free-lane model clears the Hermes 64K context floor")
    func hermesContextFloor() {
        for route in FreeLaneCatalog.routes() {
            let model = LLMModelCatalog.models(for: route.provider).first { $0.id == route.model }
            #expect(model != nil, "\(route.model) is missing from LLMModelCatalog for \(route.provider.rawValue)")
            #expect(
                (model?.contextWindow ?? 0) >= FreeLaneCatalog.hermesMinimumContextWindow,
                "\(route.model) advertises \(model?.contextWindow ?? 0), below Hermes' 64K floor"
            )
        }
    }

    /// `:free` is an OpenRouter routing directive, not part of the model id.
    /// Sending it to integrate.api.nvidia.com 404s the model.
    @Test("the NVIDIA NIM leg never carries a :free suffix")
    func nvidiaLegHasNoFreeSuffix() {
        for route in FreeLaneCatalog.routes() where route.leg == .nvidiaDirect {
            #expect(!route.model.hasSuffix(":free"))
        }
    }

    /// Regression guard for a bug that shipped: a $0 `:free` entry in the
    /// general catalogue wins cost-first scoring, so paying users get handed a
    /// rate-limited free model and the platform's account-wide free allowance
    /// gets burned by the people funding us.
    @Test("no :free slug leaks into the paying-user Auto pool")
    func routerCatalogHasNoFreeSlugs() {
        let leaked = RouterModelCatalog.entries.filter { $0.model.hasSuffix(":free") }
        #expect(leaked.isEmpty, "free slugs in RouterModelCatalog: \(leaked.map(\.model))")
    }

    @Test("no zero-cost entry in the paying-user Auto pool")
    func routerCatalogHasNoZeroCostEntries() {
        let free = RouterModelCatalog.entries.filter {
            $0.inputPerMillionUsdMicros == 0 && $0.outputPerMillionUsdMicros == 0
        }
        #expect(free.isEmpty, "zero-cost entries in RouterModelCatalog: \(free.map(\.model))")
    }

    /// These NVIDIA ids were never reachable — no adapter was registered — and
    /// the prices were placeholders. Kept as a guard so they don't reappear.
    @Test("dead NVIDIA llama entries are gone")
    func deadNvidiaEntriesRemoved() {
        let dead = ["meta/llama-3.1-8b-instruct", "meta/llama-3.1-70b-instruct", "nvidia/nemotron-3-ultra"]
        for model in dead {
            #expect(
                RouterModelCatalog.entry(provider: .nvidia, model: model) == nil,
                "\(model) is still in RouterModelCatalog"
            )
        }
    }

    /// The two legs are free for *different reasons*, and only one of them is
    /// free by construction.
    ///
    /// - `openRouterFree` uses a `:free` slug: zero-rated by OpenRouter, no
    ///   balance consumed, so it cannot bill us however much it is used.
    /// - `nvidiaDirect` uses a normal, billable NIM model id — the same one the
    ///   paid catalogue prices. It is free only while NVIDIA's finite signup
    ///   credits last. **When they run out, NVIDIA bills at list price.**
    ///   `freelane.nvidiaDailyRequests` is what bounds that exposure, so it is a
    ///   real spend ceiling and not merely a rate limit.
    @Test("the OpenRouter leg is zero-rated by slug; the NIM leg is credit-funded")
    func legCostModelsDiffer() {
        let routes = FreeLaneCatalog.routes()

        let openRouterLeg = routes.first { $0.leg == .openRouterFree }
        #expect(openRouterLeg?.model.hasSuffix(":free") == true)
        // Never catalogued — see `routerCatalogHasNoFreeSlugs`.
        #expect(RouterModelCatalog.entry(provider: .openRouter, model: openRouterLeg?.model ?? "") == nil)

        // The NIM leg is deliberately a real, priced model. If this ever becomes
        // nil, the daily-ceiling reasoning above has silently lost its basis.
        let nvidiaLeg = routes.first { $0.leg == .nvidiaDirect }
        let entry = RouterModelCatalog.entry(provider: .nvidia, model: nvidiaLeg?.model ?? "")
        #expect(entry != nil, "the NIM leg must stay a catalogued, priced model")
        #expect((entry?.inputPerMillionUsdMicros ?? 0) > 0)
    }
}
