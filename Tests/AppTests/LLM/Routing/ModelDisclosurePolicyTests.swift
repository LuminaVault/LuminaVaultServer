@testable import App
import Foundation
import LuminaVaultShared
import Testing

@Suite("ModelDisclosurePolicy")
struct ModelDisclosurePolicyTests {
    private func routingEvent() -> QueryStreamEvent {
        .routing(RouterRoutingEventDTO(
            executionID: UUID(),
            phase: .selected,
            profileID: UUID(),
            profileName: "Default",
            taskType: .coding,
            strategy: .sequential,
            activeRoutes: [RouterModelRouteDTO(provider: .openRouter, model: "openai/gpt-5")]
        ))
    }

    @Test func brainModeMapping() {
        #expect(ModelDisclosure.forBrainMode(.managed) == .hidden)
        #expect(ModelDisclosure.forBrainMode(nil) == .hidden)
        #expect(ModelDisclosure.forBrainMode(.byok) == .visible)
    }

    @Test func visiblePassesThroughUntouched() {
        let event = routingEvent()
        let out = ModelDisclosurePolicy.scrub(event, disclosure: .visible)
        #expect(out == event)
    }

    @Test func hiddenScrubsRoutingIdentity() throws {
        let out = try #require(ModelDisclosurePolicy.scrub(routingEvent(), disclosure: .hidden))
        guard case let .routing(routing) = out else {
            Issue.record("expected .routing event")
            return
        }
        #expect(routing.activeRoutes.isEmpty)
        #expect(routing.displayLabel == "Auto · coding")
        #expect(routing.taskType == .coding)
    }

    @Test func hiddenScrubsUsageIdentityButKeepsCost() throws {
        let usage = QueryStreamEvent.usage(RouterUsageDTO(
            executionID: UUID(),
            provider: .openRouter,
            model: "x-ai/grok-4",
            tokensIn: 100,
            tokensOut: 50,
            estimatedCostUsdMicros: 1234,
            latencyMs: 900,
            usageEstimated: false
        ))
        let out = try #require(ModelDisclosurePolicy.scrub(usage, disclosure: .hidden))
        guard case let .usage(scrubbed) = out else {
            Issue.record("expected .usage event")
            return
        }
        #expect(scrubbed.provider == nil)
        #expect(scrubbed.model == nil)
        #expect(scrubbed.tokensIn == 100)
        #expect(scrubbed.estimatedCostUsdMicros == 1234)
    }

    @Test func hiddenScrubsFallbackNotice() throws {
        let notice = QueryStreamEvent.fallback(ProviderFallbackNoticeDTO(
            originalProvider: .xai,
            originalModel: "grok-4",
            fallbackProvider: .openRouter,
            fallbackModel: "qwen/qwen-2.5-72b-instruct",
            reasonCode: "credit_exhausted",
            userMessage: "Grok credits exhausted — switched to Qwen 2.5 via OpenRouter"
        ))
        let out = try #require(ModelDisclosurePolicy.scrub(notice, disclosure: .hidden))
        guard case let .fallback(scrubbed) = out else {
            Issue.record("expected .fallback event")
            return
        }
        #expect(scrubbed.originalModel == ModelDisclosurePolicy.genericModelID)
        #expect(scrubbed.fallbackModel == ModelDisclosurePolicy.genericModelID)
        #expect(!scrubbed.userMessage.lowercased().contains("grok"))
        #expect(!scrubbed.userMessage.lowercased().contains("qwen"))
        #expect(scrubbed.reasonCode == "credit_exhausted")
    }

    @Test func hiddenScrubsParallelRoute() throws {
        let event = QueryStreamEvent.parallel(ParallelStreamEventDTO(
            executionID: UUID(),
            kind: .outputStarted,
            role: "worker",
            route: RouterModelRouteDTO(provider: .openRouter, model: "openai/gpt-5")
        ))
        let out = try #require(ModelDisclosurePolicy.scrub(event, disclosure: .hidden))
        guard case let .parallel(scrubbed) = out else {
            Issue.record("expected .parallel event")
            return
        }
        #expect(scrubbed.route == nil)
        #expect(scrubbed.role == "worker")
    }

    @Test func contentEventsPassThroughWhenHidden() {
        let token = QueryStreamEvent.token("hello")
        #expect(ModelDisclosurePolicy.scrub(token, disclosure: .hidden) == token)
        #expect(ModelDisclosurePolicy.scrub(.done, disclosure: .hidden) == .done)
    }

    @Test func hiddenScrubsWorkflowRunNodeIdentity() throws {
        let node = WorkflowNodeRunDTO(
            id: UUID(),
            nodeID: UUID(),
            nodeName: "Answer",
            status: .succeeded,
            attempt: 1,
            outputPreview: "done",
            provider: .openRouter,
            model: "openai/gpt-5",
            tokensIn: 12,
            tokensOut: 34,
            managedCostUsdMicros: 56
        )
        let run = WorkflowRunDTO(
            id: UUID(),
            workflowID: UUID(),
            workflowName: "Daily brief",
            version: 2,
            status: .succeeded,
            trigger: .manual,
            createdAt: Date(),
            nodeRuns: [node]
        )

        let visible = ModelDisclosurePolicy.scrub(run, disclosure: .visible)
        #expect(visible.nodeRuns.first?.provider == .openRouter)
        #expect(visible.nodeRuns.first?.model == "openai/gpt-5")

        let hidden = ModelDisclosurePolicy.scrub(run, disclosure: .hidden)
        let scrubbed = try #require(hidden.nodeRuns.first)
        #expect(scrubbed.provider == nil)
        #expect(scrubbed.model == nil)
        #expect(scrubbed.tokensIn == 12)
        #expect(scrubbed.managedCostUsdMicros == 56)
    }

    @Test func hiddenScrubsWorkflowRunEventIdentity() {
        let event = WorkflowRunEventDTO(
            id: 1,
            runID: UUID(),
            kind: .nodeOutput,
            nodeID: UUID(),
            message: "Managed provider unavailable; retrying on OpenRouter Free.",
            data: [
                "provider": "openRouter",
                "model": "anthropic/claude-sonnet-4.6",
                "fallback": "openrouter/free",
                "reason": "providerUnavailable",
            ],
            createdAt: Date()
        )

        let visible = ModelDisclosurePolicy.scrub(event, disclosure: .visible)
        #expect(visible.data["model"] == "anthropic/claude-sonnet-4.6")

        let hidden = ModelDisclosurePolicy.scrub(event, disclosure: .hidden)
        #expect(hidden.data["provider"] == nil)
        #expect(hidden.data["model"] == nil)
        #expect(hidden.data["fallback"] == nil)
        #expect(hidden.data["reason"] == "providerUnavailable")
        #expect(hidden.message == "Managed provider unavailable; retrying on a backup route.")
    }

    @Test func hiddenScrubsParallelExecutionDetailRoutes() throws {
        let summary = ParallelExecutionSummaryDTO(
            id: UUID(),
            strategy: .consensus,
            status: .completed,
            promptPreview: "compare",
            participantCount: 2,
            estimatedCostUsdMicros: 100,
            latencyMs: 20,
            createdAt: Date()
        )
        let output = ParallelOutputDTO(
            id: UUID(),
            role: "worker",
            route: RouterModelRouteDTO(provider: .openRouter, model: "anthropic/claude-sonnet-4.6"),
            stage: .answer,
            round: 1,
            content: "result",
            status: "ok",
            tokensIn: 10,
            tokensOut: 5,
            estimatedCostUsdMicros: 99,
            latencyMs: 42
        )
        let detail = ParallelExecutionDetailDTO(
            summary: summary,
            prompt: "compare options",
            outputs: [output],
            synthesizedAnswer: "result"
        )

        let visible = try #require(ModelDisclosurePolicy.scrub(detail, disclosure: .visible).outputs.first)
        #expect(visible.route.model == "anthropic/claude-sonnet-4.6")

        let hidden = try #require(ModelDisclosurePolicy.scrub(detail, disclosure: .hidden).outputs.first)
        #expect(hidden.route.provider == .openRouter)
        #expect(hidden.route.model == ModelDisclosurePolicy.genericModelID)
        #expect(hidden.content == "result")
        #expect(hidden.tokensOut == 5)
    }

    @Test func hiddenScrubsMemoryProvenanceAndFacets() throws {
        let contribution = MemoryContributionDTO(
            id: UUID(),
            operation: .create,
            actor: .model,
            source: .chat,
            model: ModelProvenanceDTO(provider: "openrouter", model: "x-ai/grok-4"),
            sourceReference: "message",
            createdAt: Date()
        )
        let summary = MemoryProvenanceSummaryDTO(
            createdBy: contribution,
            contributors: [ModelProvenanceDTO(provider: "openrouter", model: "x-ai/grok-4")]
        )
        let memory = MemoryDTO(
            id: UUID(),
            content: "remember this",
            tags: ["chat"],
            reviewState: MemoryReviewState.auto,
            provenance: summary
        )
        let response = MemoryProvenanceResponse(memoryID: memory.id, contributions: [contribution])
        let facets = MemoryFacetsResponse(
            providers: [MemoryFacetDTO(value: "openrouter", count: 1)],
            models: [MemoryFacetDTO(value: "x-ai/grok-4", count: 1)],
            sources: [MemoryFacetDTO(value: "chat", count: 1)]
        )

        let visible = ModelDisclosurePolicy.scrub(memory, disclosure: .visible)
        #expect(visible.provenance?.createdBy?.model?.model == "x-ai/grok-4")

        let hiddenMemory = ModelDisclosurePolicy.scrub(memory, disclosure: .hidden)
        #expect(hiddenMemory.provenance?.createdBy?.model == nil)
        #expect(hiddenMemory.provenance?.contributors.isEmpty == true)

        let hiddenResponse = try #require(ModelDisclosurePolicy.scrub(response, disclosure: .hidden).contributions.first)
        #expect(hiddenResponse.model == nil)

        let hiddenFacets = ModelDisclosurePolicy.scrub(facets, disclosure: .hidden)
        #expect(hiddenFacets.providers.isEmpty)
        #expect(hiddenFacets.models.isEmpty)
        #expect(hiddenFacets.sources.first?.value == "chat")
    }
}

@Suite("Chat prompt model-identity guard")
struct ChatPromptIdentityGuardTests {
    @Test func guardInjectedOnlyWhenHidden() {
        let guarded = ConversationController.buildPrompt(
            history: [],
            hits: [],
            includeModelIdentityGuard: true
        )
        let open = ConversationController.buildPrompt(
            history: [],
            hits: [],
            includeModelIdentityGuard: false
        )
        #expect(guarded.first?.role == "system")
        #expect(guarded.first?.content.contains("Never disclose, confirm, or deny") == true)
        #expect(open.first?.content.contains("Never disclose") == false)
    }

    @Test func hitProvenanceModelNamesScrubbedWhenHidden() {
        let hit = MemorySearchResult(
            id: UUID(),
            tenantID: UUID(),
            content: "remember the roadmap",
            createdAt: Date(),
            distance: 0.1,
            source: .chat,
            provider: "openrouter",
            model: "openai/gpt-5"
        )
        let guarded = ConversationController.buildPrompt(
            history: [],
            hits: [hit],
            includeModelIdentityGuard: true
        )
        let system = guarded.first?.content ?? ""
        #expect(system.contains("prior assistant output"))
        #expect(!system.contains("openai/gpt-5"))

        let open = ConversationController.buildPrompt(
            history: [],
            hits: [hit],
            includeModelIdentityGuard: false
        )
        #expect(open.first?.content.contains("openai/gpt-5") == true)
    }
}

@Suite("Query prompt model-identity guard")
struct QueryPromptIdentityGuardTests {
    @Test func guardAndProvenanceScrubUnderManaged() {
        let hit = MemorySearchResult(
            id: UUID(),
            tenantID: UUID(),
            content: "note",
            createdAt: Date(),
            distance: 0.2,
            source: .chat,
            provider: "openrouter",
            model: "x-ai/grok-4"
        )
        let guarded = QueryController.buildPrompt(
            query: "which model are you?",
            hits: [hit],
            includeModelIdentityGuard: true
        )
        let system = guarded.first?.content ?? ""
        #expect(system.contains("Never disclose, confirm, or deny"))
        #expect(!system.contains("x-ai/grok-4"))

        let open = QueryController.buildPrompt(query: "q", hits: [hit])
        #expect(open.first?.content.contains("x-ai/grok-4") == true)
        #expect(open.first?.content.contains("Never disclose") == false)
    }
}
