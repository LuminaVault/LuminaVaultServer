import LuminaVaultShared

enum RouterModelCatalog {
    /// Deliberately versioned in code. These are routing estimates, not billing
    /// invoices; vendor price changes are reviewed and shipped explicitly.
    static let entries: [RouterModelCatalogEntryDTO] = [
        .init(
            provider: .openRouter,
            model: "qwen/qwen-2.5-72b-instruct",
            displayName: "Qwen 2.5 72B",
            taskQuality: ratings(general: 82, reasoning: 84, coding: 78, search: 65, summarization: 83),
            inputPerMillionUsdMicros: 350_000,
            outputPerMillionUsdMicros: 400_000,
            defaultLatencyMs: 1100,
            capabilities: ["chat", "tools"]
        ),
        .init(
            provider: .anthropic,
            model: "claude-sonnet-4-6",
            displayName: "Claude Sonnet 4.6",
            taskQuality: ratings(general: 94, reasoning: 96, coding: 95, search: 76, summarization: 96),
            inputPerMillionUsdMicros: 3_000_000,
            outputPerMillionUsdMicros: 15_000_000,
            defaultLatencyMs: 1500,
            capabilities: ["chat", "tools", "reasoning"]
        ),
        .init(
            provider: .openai,
            model: "gpt-5",
            displayName: "GPT-5",
            taskQuality: ratings(general: 95, reasoning: 96, coding: 94, search: 80, summarization: 94),
            inputPerMillionUsdMicros: 1_250_000,
            outputPerMillionUsdMicros: 10_000_000,
            defaultLatencyMs: 1700,
            capabilities: ["chat", "tools", "reasoning"]
        ),
        .init(
            provider: .gemini,
            model: "gemini-2.5-pro",
            displayName: "Gemini 2.5 Pro",
            taskQuality: ratings(general: 91, reasoning: 92, coding: 89, search: 90, summarization: 92),
            inputPerMillionUsdMicros: 1_250_000,
            outputPerMillionUsdMicros: 10_000_000,
            defaultLatencyMs: 1250,
            capabilities: ["chat", "tools", "search"]
        ),
        .init(
            provider: .xai,
            model: "grok-4",
            displayName: "Grok 4",
            taskQuality: ratings(general: 91, reasoning: 92, coding: 88, search: 96, summarization: 88),
            inputPerMillionUsdMicros: 3_000_000,
            outputPerMillionUsdMicros: 15_000_000,
            defaultLatencyMs: 1350,
            capabilities: ["chat", "tools", "search"]
        ),
        .init(
            provider: .nvidia,
            model: "meta/llama-3.3-70b-instruct",
            displayName: "Llama 3.3 70B (NVIDIA)",
            taskQuality: ratings(general: 80, reasoning: 78, coding: 77, search: 60, summarization: 82),
            inputPerMillionUsdMicros: 600_000,
            outputPerMillionUsdMicros: 600_000,
            defaultLatencyMs: 850,
            capabilities: ["chat", "tools"]
        ),
    ]

    static func entry(provider: ProviderID, model: String) -> RouterModelCatalogEntryDTO? {
        entries.first { $0.provider == provider && $0.model == model }
    }

    private static func ratings(
        general: Int,
        reasoning: Int,
        coding: Int,
        search: Int,
        summarization: Int
    ) -> [String: Int] {
        [
            RouterTaskType.general.rawValue: general,
            RouterTaskType.reasoning.rawValue: reasoning,
            RouterTaskType.coding.rawValue: coding,
            RouterTaskType.search.rawValue: search,
            RouterTaskType.summarization.rawValue: summarization,
            RouterTaskType.extraction.rawValue: summarization,
            RouterTaskType.creative.rawValue: general,
            RouterTaskType.automation.rawValue: coding,
        ]
    }
}
