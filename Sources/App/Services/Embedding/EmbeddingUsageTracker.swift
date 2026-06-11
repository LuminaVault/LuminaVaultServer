import Foundation
import Logging

/// HER-134 — cost guard. Wraps any `EmbeddingService` with a pre-call cap
/// check + post-success counter. Cap is sourced from env; per-tenant
/// override lives in a follow-up ticket. `cap == 0` disables the guard
/// (dev). Counter is keyed by `(tenant_id, year_month)`; rollover is
/// automatic when the calendar month advances.
///
/// Tokens-per-call: the wrapped provider doesn't return tokens (the
/// `EmbeddingService` protocol has no out parameter), so the tracker
/// records an **estimate** based on input length when no real count is
/// available. `OpenAIEmbeddingService` may invoke `recordReal` directly
/// via the usageCallback parameter; that path replaces the estimate.
actor EmbeddingUsageTracker: EmbeddingService {
    private let inner: any EmbeddingService
    private let usage: EmbeddingUsageRepository
    private let monthlyCap: Int64
    private let logger: Logger

    /// `cap == 0` disables enforcement (still logs). `cap > 0` rejects
    /// embed calls when the running monthly total has reached or exceeded
    /// the cap.
    init(
        inner: any EmbeddingService,
        usage: EmbeddingUsageRepository,
        monthlyCap: Int64,
        logger: Logger = Logger(label: "lv.embedding.usage")
    ) {
        self.inner = inner
        self.usage = usage
        self.monthlyCap = monthlyCap
        self.logger = logger
    }

    func embed(_ text: String, tenantID: UUID) async throws -> [Float] {
        if monthlyCap > 0 {
            let used = await (try? usage.tokensThisMonth(tenantID: tenantID)) ?? 0
            if used >= monthlyCap {
                logger.warning("embedding cap exceeded: tenant=\(tenantID) used=\(used) cap=\(monthlyCap)")
                throw EmbeddingProviderError.capExceeded(tenantID: tenantID, monthlyTokens: used, cap: monthlyCap)
            }
        }
        let vec = try await inner.embed(text, tenantID: tenantID)
        let estimate = Self.estimateTokens(for: text)
        do {
            try await usage.increment(tenantID: tenantID, tokens: estimate)
        } catch {
            logger.warning("embedding usage increment failed: \(error)")
        }
        return vec
    }

    /// 4 chars/token heuristic — same fudge OpenAI's tokenizer cookbook
    /// uses as a back-of-envelope. Min 1 to avoid zero-cost rows.
    static func estimateTokens(for text: String) -> Int64 {
        let chars = Int64(text.count)
        return max(1, (chars + 3) / 4)
    }
}
