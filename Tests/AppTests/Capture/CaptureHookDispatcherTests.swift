@testable import App
import Foundation
import Logging
import Testing

// HER-54 (Slice 1) — capture-hook engine. Pure dispatch logic, no DB, so it
// avoids the AsyncKit teardown SIGILL (HER-310) exactly like the Slice 2
// connector tests. The DB read in `run()` is covered by build + manual E2E.

private struct CaptureTestError: Error {}

/// Configurable stub hook: binds to a slug, declares a hook point, and runs a
/// caller-supplied transform (which may throw, to exercise failure isolation).
private struct StubHook: CaptureHook {
    let binding: String
    let hookPoint: CaptureHookPoint
    let transform: @Sendable (CaptureHookContext) throws -> CaptureHookContext

    func apply(_ context: CaptureHookContext) async throws -> CaptureHookContext {
        try transform(context)
    }
}

private func makeContext(description: String?, body: String? = nil) -> CaptureHookContext {
    CaptureHookContext(
        tenantID: UUID(),
        url: "https://example.com/article",
        config: [:],
        metadata: EnrichedMetadata(
            title: "Example",
            description: description,
            imageURL: nil,
            author: nil,
            url: "https://example.com/article",
            transcript: nil,
            body: body,
            readingTimeMinutes: nil
        )
    )
}

private func makeDispatcher(hooks: [any CaptureHook]) -> CaptureHookDispatcher {
    CaptureHookDispatcher(
        fluent: nil,
        registry: CaptureHookRegistry(hooks: hooks),
        logger: Logger(label: "test.capture.hooks")
    )
}

@Suite("Capture hook dispatcher", .disabled(if: IntegrationTestEnv.runIntegrationOnly))
struct CaptureHookDispatcherTests {
    @Test
    func `reading-time hook installed transforms metadata at postEnrich`() async {
        let dispatcher = makeDispatcher(hooks: [ReadingTimeHook()])
        // 400 words at 200 wpm → 2 minutes.
        let ctx = makeContext(description: String(repeating: "lorem ", count: 400))

        let result = await dispatcher.dispatch(
            point: .postEnrich,
            installedSlugs: ["reading-time"],
            context: ctx
        )

        #expect(result.metadata.readingTimeMinutes == 2)
    }

    @Test
    func `not installed leaves metadata unchanged`() async {
        let dispatcher = makeDispatcher(hooks: [ReadingTimeHook()])
        let ctx = makeContext(description: String(repeating: "lorem ", count: 400))

        let result = await dispatcher.dispatch(
            point: .postEnrich,
            installedSlugs: [],
            context: ctx
        )

        #expect(result.metadata.readingTimeMinutes == nil)
    }

    @Test
    func `non-captureHook install is ignored`() async {
        // A reading-time hook is registered, but the installed slug is a
        // connector (readwise) — wrong capability kind, so nothing runs.
        let dispatcher = makeDispatcher(hooks: [ReadingTimeHook()])
        let ctx = makeContext(description: String(repeating: "lorem ", count: 400))

        let result = await dispatcher.dispatch(
            point: .postEnrich,
            installedSlugs: ["readwise"],
            context: ctx
        )

        #expect(result.metadata.readingTimeMinutes == nil)
    }

    @Test
    func `throwing hook is isolated and capture is unaffected`() async {
        let failing = StubHook(binding: "reading-time", hookPoint: .postEnrich) { _ in
            throw CaptureTestError()
        }
        let dispatcher = makeDispatcher(hooks: [failing])
        let ctx = makeContext(description: "untouched")

        let result = await dispatcher.dispatch(
            point: .postEnrich,
            installedSlugs: ["reading-time"],
            context: ctx
        )

        // Context returned intact; no crash, no propagation.
        #expect(result.metadata.description == "untouched")
        #expect(result.metadata.readingTimeMinutes == nil)
    }

    @Test
    func `hook for a different point does not run`() async {
        // This hook would stamp a sentinel reading time if it ran, but it is
        // registered for `.beforePersist`, so a `.postEnrich` dispatch skips it.
        let beforePersistHook = StubHook(binding: "reading-time", hookPoint: .beforePersist) { context in
            var ctx = context
            ctx.metadata.readingTimeMinutes = 999
            return ctx
        }
        let dispatcher = makeDispatcher(hooks: [beforePersistHook])
        let ctx = makeContext(description: "x")

        let result = await dispatcher.dispatch(
            point: .postEnrich,
            installedSlugs: ["reading-time"],
            context: ctx
        )

        #expect(result.metadata.readingTimeMinutes == nil)
    }

    @Test
    func `reading-time is a captureHook entry in the catalog`() {
        let entry = PluginCatalog.entry(slug: "reading-time")
        #expect(entry?.binding == "reading-time")
        #expect(entry?.dto.capabilityKind == .captureHook)
        #expect(entry?.dto.category == .capture)
        #expect(entry?.dto.configFields.isEmpty == true)
    }
}
