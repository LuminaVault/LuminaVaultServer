import Foundation

/// HER-176 — origin classification for LLM model weights, used by
/// `ModelRouter` (HER-161) to honor a user's `privacy_no_cn_origin` opt-out.
///
/// `Origin` is the *weight* origin, NOT the host. DeepSeek-V3 served from
/// Together / Groq / Fireworks / DeepInfra is still `.cn` because the
/// privacy concern is the model's training pipeline, not the inference
/// endpoint. Hosts: see `docs/llm-models.md`.
enum ModelOrigin: String, Sendable, Codable, CaseIterable {
    case us
    case eu
    case cn
}

/// Hard-coded list of model identifiers whose weights originated in CN.
/// Keep in lock-step with `docs/llm-models.md`. Adding a new vendor's model
/// requires:
///   1. Update this enum case if it's a new origin
///   2. Add the model identifier to `cnOriginModels`
///   3. Update `docs/llm-models.md` so the iOS Settings copy stays accurate
enum ModelOriginRegistry {
    /// Lowercased substrings matched against the model identifier. Substring
    /// match (rather than exact) handles `deepseek/deepseek-r1-0528` and
    /// `together_ai/deepseek-ai/DeepSeek-V3` in one entry.
    static let cnOriginSubstrings: [String] = [
        "deepseek",
        "qwen",
        "kimi",
        "moonshot", // Kimi-2 ships under the moonshot label on some hosts
        "yi-",      // 01.AI Yi family
    ]

    /// Returns true when the given model identifier contains any CN-origin
    /// substring. Case-insensitive.
    static func isCNOrigin(_ modelID: String) -> Bool {
        let lower = modelID.lowercased()
        return cnOriginSubstrings.contains { lower.contains($0) }
    }

    /// Filters a candidate list to honor the user's privacy preference.
    /// `privacyNoCNOrigin == false` is a no-op. ModelRouter calls this on
    /// the candidate set BEFORE applying tier / capability scoring so the
    /// fallback path is selected from the surviving (non-CN) models.
    static func filter<C: Collection>(
        _ models: C,
        privacyNoCNOrigin: Bool
    ) -> [C.Element] where C.Element: ModelIdentifying {
        guard privacyNoCNOrigin else { return Array(models) }
        return models.filter { !isCNOrigin($0.modelID) }
    }
}

/// Minimal contract a model candidate must satisfy to be filterable.
/// `ModelRouter`'s candidate type (HER-161) will conform.
protocol ModelIdentifying {
    var modelID: String { get }
}

extension String: ModelIdentifying {
    var modelID: String { self }
}
