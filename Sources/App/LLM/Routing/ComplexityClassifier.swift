import Foundation
import LuminaVaultShared

/// Heuristic turn complexity classifier for Auto (Smart) routing.
/// Pure CPU, no I/O — target &lt;1ms on typical prompts.
enum ComplexityClassifier {
    /// Classify a single user prompt (+ optional surface floor).
    static func classify(_ prompt: String, surface: RouterSurface) -> RouterComplexity {
        // Jobs/skills default to at least medium — automation paths are higher stakes.
        let surfaceFloor: RouterComplexity = (surface == .job || surface == .skill) ? .medium : .low

        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return max(surfaceFloor, .low)
        }

        let lower = trimmed.lowercased()
        let tokenEstimate = max(1, trimmed.count / 4)
        let codeFenceCount = trimmed.components(separatedBy: "```").count - 1
        let hasCodeFence = codeFenceCount >= 2
        let lineCount = trimmed.split(separator: "\n", omittingEmptySubsequences: false).count

        var score = 0

        // Length / structure
        if tokenEstimate >= 2000 || lineCount >= 40 {
            score += 3
        } else if tokenEstimate >= 400 || lineCount >= 12 {
            score += 1
        }

        if hasCodeFence {
            score += 2
        }
        if trimmed.filter(\.isNewline).count > 20 {
            score += 1
        }

        // High-complexity keywords
        let highSignals = [
            "debug", "refactor", "architecture", "prove", "optimize algorithm",
            "lock-free", "race condition", "distributed", "multi-step",
            "deep analysis", "trade-off", "tradeoff", "implement end-to-end",
            "production-ready", "security audit", "performance profile",
        ]
        if highSignals.contains(where: { lower.contains($0) }) {
            score += 3
        }

        // Medium keywords
        let mediumSignals = [
            "plan", "compare", "design", "implement", "write a", "explain why",
            "analyze", "review", "migrate", "api", "function", "class ",
        ]
        if mediumSignals.contains(where: { lower.contains($0) }) {
            score += 1
        }

        // Strong low signals (only if not already elevated)
        let lowSignals = [
            "hi", "hello", "thanks", "thank you", "what is ", "what's ",
            "define ", "tl;dr", "summarize this", "2+2", "quick question",
        ]
        let looksTrivial = tokenEstimate < 80
            && !hasCodeFence
            && (lowSignals.contains(where: { lower.hasPrefix($0) || lower.contains($0) })
                || lower.split(separator: " ").count <= 12)

        if looksTrivial, score == 0 {
            return max(surfaceFloor, .low)
        }

        // Conservative: bias up when uncertain
        let raw: RouterComplexity = if score >= 4 {
            .high
        } else if score >= 2 {
            .medium
        } else if score >= 1 {
            .medium // conservative mid when any signal
        } else {
            .low
        }
        return max(surfaceFloor, raw)
    }
}
