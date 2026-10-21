import Foundation
import Logging

/// HER-134 — try the primary provider; on `.transient` or `.network`
/// failure, walk the fallback list until one succeeds. `.permanent`
/// errors short-circuit (no fallback). When every provider has failed
/// the wrapper rethrows the last error so callers see the actionable
/// failure mode (rate-limit vs auth vs decode).
final class EmbeddingFallbackService: EmbeddingService {
    private let primary: any EmbeddingService
    private let primaryKind: EmbeddingProviderKind
    private let fallbacks: [(EmbeddingProviderKind, any EmbeddingService)]
    private let logger: Logger

    init(
        primary: any EmbeddingService,
        primaryKind: EmbeddingProviderKind,
        fallbacks: [(EmbeddingProviderKind, any EmbeddingService)],
        logger: Logger = Logger(label: "lv.embedding.fallback")
    ) {
        self.primary = primary
        self.primaryKind = primaryKind
        self.fallbacks = fallbacks
        self.logger = logger
    }

    func embed(_ text: String, tenantID: UUID) async throws -> [Float] {
        var lastError: Error?
        let chain: [(EmbeddingProviderKind, any EmbeddingService)] =
            [(primaryKind, primary)] + fallbacks
        for (kind, service) in chain {
            do {
                let vec = try await service.embed(text, tenantID: tenantID)
                if lastError != nil {
                    logger.info("embedding recovered via fallback: \(kind.rawValue)")
                }
                return vec
            } catch let err as EmbeddingProviderError {
                lastError = err
                if !err.isRecoverable {
                    // An empty balance fails every embed until someone tops
                    // up, so it is an error (the Loki error-rate alert sees
                    // it), not one more warning.
                    if case .permanent(reason: .paymentRequired, _) = err {
                        logger.error("embedding permanent failure: provider=\(kind.rawValue) \(err)")
                    } else {
                        logger.warning("embedding permanent failure: provider=\(kind.rawValue) \(err)")
                    }
                    throw err
                }
                logger.warning("embedding recoverable failure: provider=\(kind.rawValue) \(err)")
                continue
            } catch {
                lastError = error
                logger.warning("embedding unexpected failure: provider=\(kind.rawValue) err=\(error)")
                continue
            }
        }
        if let last = lastError {
            throw last
        }
        throw EmbeddingProviderError.permanent(reason: .allProvidersFailed)
    }
}
