import Foundation

/// HER-54 (Slice 1) — sample first-party capture hook proving the
/// `.postEnrich` path end-to-end. Deterministic (no network, no config):
/// estimates reading time from the enriched text and writes it into
/// `EnrichedMetadata.readingTimeMinutes`, which the pipeline renders into the
/// vault file frontmatter as `reading_time`.
struct ReadingTimeHook: CaptureHook {
    let binding = "reading-time"
    let hookPoint = CaptureHookPoint.postEnrich

    /// Average adult prose reading speed. Round up so any non-empty article is
    /// at least 1 minute.
    static let wordsPerMinute = 200

    func apply(_ context: CaptureHookContext) async throws -> CaptureHookContext {
        let text = [
            context.metadata.description,
            context.metadata.transcript,
            context.metadata.body,
        ]
        .compactMap(\.self)
        .joined(separator: " ")

        let wordCount = text.split { $0.isWhitespace || $0.isNewline }.count
        guard wordCount > 0 else { return context }

        var ctx = context
        let minutes = Int((Double(wordCount) / Double(Self.wordsPerMinute)).rounded(.up))
        ctx.metadata.readingTimeMinutes = max(1, minutes)
        return ctx
    }
}
