@testable import App
import LuminaVaultShared
import Testing

@Suite("Managed model catalog")
struct ManagedModelCatalogTests {
    @Test
    func `managed default has an OpenRouter catalog entry`() throws {
        let entry = try #require(RouterModelCatalog.entry(
            provider: ManagedLLMDefaults.provider,
            model: ManagedLLMDefaults.model
        ))

        #expect(entry.displayName == "DeepSeek V4 Flash")
        #expect(entry.inputPerMillionUsdMicros == 90000)
        #expect(entry.outputPerMillionUsdMicros == 180_000)
        #expect(entry.capabilities.contains("tools"))
        #expect(entry.capabilities.contains("reasoning"))
    }
}

@Suite("ComplexityClassifier")
struct ComplexityClassifierTests {
    @Test func simpleGreetingIsLow() {
        let c = ComplexityClassifier.classify("hi there", surface: .chat)
        #expect(c == .low)
    }

    @Test func simpleMathIsLow() {
        let c = ComplexityClassifier.classify("what is 2+2?", surface: .chat)
        #expect(c == .low)
    }

    @Test func shortSummaryIsLowOrMedium() {
        let c = ComplexityClassifier.classify("summarize this: the cat sat on the mat", surface: .chat)
        #expect(c == .low || c == .medium)
    }

    @Test func complexDebugIsHigh() {
        let prompt = """
        Please debug and refactor this distributed lock-free queue. Prove correctness
        and optimize the algorithm for multi-step concurrent access.

        ```swift
        // large code block
        \(String(repeating: "func f() {}\n", count: 50))
        ```
        """
        let c = ComplexityClassifier.classify(prompt, surface: .chat)
        #expect(c == .high)
    }

    @Test func jobSurfaceFloorsAtMedium() {
        let c = ComplexityClassifier.classify("hi", surface: .job)
        #expect(c >= .medium)
    }

    @Test func implementPlanIsAtLeastMedium() {
        let c = ComplexityClassifier.classify(
            "Please plan and implement a migration for the auth service API",
            surface: .chat
        )
        #expect(c >= .medium)
    }
}

@Suite("AvailableModelPoolBuilder")
struct AvailableModelPoolBuilderTests {
    @Test func byokOnlyUsesCredentialedProviders() {
        let pool = AvailableModelPoolBuilder.build(.init(
            mode: .byok,
            profileRoutes: [
                RouterModelRouteDTO(provider: .anthropic, model: "claude-opus-4-1"),
                RouterModelRouteDTO(provider: .openai, model: "gpt-4o"),
            ],
            allowedProviders: [],
            blockedProviders: [],
            credentialedProviders: [.anthropic],
            deploymentEnabledProviders: [.openRouter],
            minTier: .fast
        ))
        #expect(pool.allSatisfy { $0.provider == .anthropic })
        #expect(pool.contains { $0.model.contains("haiku") || AvailableModelPoolBuilder.tier(for: $0) == .fast })
    }

    @Test func tierFloorDropsCheapWhenHigh() {
        let pool = AvailableModelPoolBuilder.build(.init(
            mode: .byok,
            profileRoutes: [
                RouterModelRouteDTO(provider: .anthropic, model: "claude-3-5-haiku-20241022"),
                RouterModelRouteDTO(provider: .anthropic, model: "claude-opus-4-1"),
            ],
            allowedProviders: [],
            blockedProviders: [],
            credentialedProviders: [.anthropic],
            deploymentEnabledProviders: [],
            minTier: .max
        ))
        #expect(pool.allSatisfy { AvailableModelPoolBuilder.tier(for: $0) >= .max })
    }

    @Test func reasonStringsAreNonEmpty() {
        let route = RouterModelRouteDTO(provider: .gemini, model: "gemini-2.5-flash")
        let reason = AvailableModelPoolBuilder.reason(
            policy: .autoSmart,
            complexity: .low,
            task: .general,
            selected: route,
            deferred: false
        )
        #expect(reason.contains("Auto"))
        let deferred = AvailableModelPoolBuilder.reason(
            policy: .locked,
            complexity: .low,
            task: .general,
            selected: route,
            deferred: true
        )
        #expect(deferred.contains("Hermes"))
    }
}
