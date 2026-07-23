import LuminaVaultShared

enum RouterModelCatalog {
    /// Deliberately versioned in code. These are routing estimates, not billing
    /// invoices; vendor price changes are reviewed and shipped explicitly.
    static let entries: [RouterModelCatalogEntryDTO] = [
        // ── Fast tier ──────────────────────────────────────────────
        .init(
            provider: .anthropic,
            model: "claude-3-5-haiku-20241022",
            displayName: "Claude 3.5 Haiku",
            taskQuality: ratings(general: 78, reasoning: 72, coding: 74, search: 60, summarization: 80),
            inputPerMillionUsdMicros: 800_000,
            outputPerMillionUsdMicros: 4_000_000,
            defaultLatencyMs: 600,
            capabilities: ["chat", "tools"],
            tier: .fast
        ),
        .init(
            provider: .gemini,
            model: "gemini-2.5-flash",
            displayName: "Gemini 2.5 Flash",
            taskQuality: ratings(general: 82, reasoning: 78, coding: 76, search: 85, summarization: 84),
            inputPerMillionUsdMicros: 150_000,
            outputPerMillionUsdMicros: 600_000,
            defaultLatencyMs: 500,
            capabilities: ["chat", "tools", "search"],
            tier: .fast
        ),
        .init(
            provider: .gemini,
            model: "gemini-2.5-flash-lite",
            displayName: "Gemini 2.5 Flash Lite",
            taskQuality: ratings(general: 74, reasoning: 68, coding: 70, search: 72, summarization: 76),
            inputPerMillionUsdMicros: 75000,
            outputPerMillionUsdMicros: 300_000,
            defaultLatencyMs: 400,
            capabilities: ["chat"],
            tier: .fast
        ),
        .init(
            provider: .openai,
            model: "gpt-4o-mini",
            displayName: "GPT-4o mini",
            taskQuality: ratings(general: 80, reasoning: 76, coding: 78, search: 70, summarization: 82),
            inputPerMillionUsdMicros: 150_000,
            outputPerMillionUsdMicros: 600_000,
            defaultLatencyMs: 550,
            capabilities: ["chat", "tools"],
            tier: .fast
        ),
        .init(
            provider: .openRouter,
            model: ManagedLLMDefaults.model,
            displayName: "DeepSeek V4 Flash",
            taskQuality: ratings(general: 88, reasoning: 90, coding: 91, search: 65, summarization: 88),
            inputPerMillionUsdMicros: 90000,
            outputPerMillionUsdMicros: 180_000,
            defaultLatencyMs: 600,
            capabilities: ["chat", "tools", "reasoning"],
            tier: .fast
        ),
        .init(
            provider: .xai,
            model: "grok-3-mini",
            displayName: "Grok 3 mini",
            taskQuality: ratings(general: 78, reasoning: 76, coding: 74, search: 80, summarization: 76),
            inputPerMillionUsdMicros: 300_000,
            outputPerMillionUsdMicros: 500_000,
            defaultLatencyMs: 700,
            capabilities: ["chat", "tools"],
            tier: .fast
        ),
        .init(
            provider: .nvidia,
            model: "meta/llama-3.1-8b-instruct",
            displayName: "Llama 3.1 8B (NVIDIA)",
            taskQuality: ratings(general: 70, reasoning: 66, coding: 68, search: 55, summarization: 72),
            inputPerMillionUsdMicros: 50000,
            outputPerMillionUsdMicros: 50000,
            defaultLatencyMs: 450,
            capabilities: ["chat"],
            tier: .fast
        ),

        // ── Balanced tier ──────────────────────────────────────────
        .init(
            provider: .openRouter,
            model: "qwen/qwen-2.5-72b-instruct",
            displayName: "Qwen 2.5 72B",
            taskQuality: ratings(general: 82, reasoning: 84, coding: 78, search: 65, summarization: 83),
            inputPerMillionUsdMicros: 350_000,
            outputPerMillionUsdMicros: 400_000,
            defaultLatencyMs: 1100,
            capabilities: ["chat", "tools"],
            tier: .balanced
        ),
        .init(
            provider: .anthropic,
            model: "claude-sonnet-4-6",
            displayName: "Claude Sonnet 4.6",
            taskQuality: ratings(general: 94, reasoning: 96, coding: 95, search: 76, summarization: 96),
            inputPerMillionUsdMicros: 3_000_000,
            outputPerMillionUsdMicros: 15_000_000,
            defaultLatencyMs: 1500,
            capabilities: ["chat", "tools", "reasoning"],
            tier: .balanced
        ),
        .init(
            provider: .openai,
            model: "gpt-4o",
            displayName: "GPT-4o",
            taskQuality: ratings(general: 90, reasoning: 88, coding: 90, search: 78, summarization: 90),
            inputPerMillionUsdMicros: 2_500_000,
            outputPerMillionUsdMicros: 10_000_000,
            defaultLatencyMs: 1200,
            capabilities: ["chat", "tools"],
            tier: .balanced
        ),
        .init(
            provider: .gemini,
            model: "gemini-2.5-pro",
            displayName: "Gemini 2.5 Pro",
            taskQuality: ratings(general: 91, reasoning: 92, coding: 89, search: 90, summarization: 92),
            inputPerMillionUsdMicros: 1_250_000,
            outputPerMillionUsdMicros: 10_000_000,
            defaultLatencyMs: 1250,
            capabilities: ["chat", "tools", "search"],
            tier: .balanced
        ),
        .init(
            provider: .xai,
            model: "grok-4",
            displayName: "Grok 4",
            taskQuality: ratings(general: 91, reasoning: 92, coding: 88, search: 96, summarization: 88),
            inputPerMillionUsdMicros: 3_000_000,
            outputPerMillionUsdMicros: 15_000_000,
            defaultLatencyMs: 1350,
            capabilities: ["chat", "tools", "search"],
            tier: .max
        ),
        .init(
            provider: .nvidia,
            model: "meta/llama-3.3-70b-instruct",
            displayName: "Llama 3.3 70B (NVIDIA)",
            taskQuality: ratings(general: 80, reasoning: 78, coding: 77, search: 60, summarization: 82),
            inputPerMillionUsdMicros: 600_000,
            outputPerMillionUsdMicros: 600_000,
            defaultLatencyMs: 850,
            capabilities: ["chat", "tools"],
            tier: .balanced
        ),

        // ── Max tier ───────────────────────────────────────────────
        .init(
            provider: .openai,
            model: "gpt-5",
            displayName: "GPT-5",
            taskQuality: ratings(general: 95, reasoning: 96, coding: 94, search: 80, summarization: 94),
            inputPerMillionUsdMicros: 1_250_000,
            outputPerMillionUsdMicros: 10_000_000,
            defaultLatencyMs: 1700,
            capabilities: ["chat", "tools", "reasoning"],
            tier: .max
        ),
        .init(
            provider: .anthropic,
            model: "claude-opus-4-1",
            displayName: "Claude Opus 4.1",
            taskQuality: ratings(general: 97, reasoning: 98, coding: 96, search: 78, summarization: 97),
            inputPerMillionUsdMicros: 15_000_000,
            outputPerMillionUsdMicros: 75_000_000,
            defaultLatencyMs: 2200,
            capabilities: ["chat", "tools", "reasoning"],
            tier: .max
        ),
        .init(
            provider: .openai,
            model: "o3",
            displayName: "o3 (reasoning)",
            taskQuality: ratings(general: 94, reasoning: 98, coding: 95, search: 70, summarization: 90),
            inputPerMillionUsdMicros: 10_000_000,
            outputPerMillionUsdMicros: 40_000_000,
            defaultLatencyMs: 3000,
            capabilities: ["chat", "reasoning"],
            tier: .max
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
