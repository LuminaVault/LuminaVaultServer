@testable import App
import enum LuminaVaultShared.HermesWhatsAppPairEvent
import enum LuminaVaultShared.HermesWhatsAppPairStatus
import Testing

/// Unit tests for the pure stdout → `HermesWhatsAppPairEvent` parser. No DB or
/// docker — feeds canned lines and asserts the emitted events. The marker
/// strings these assert against are the informed defaults in
/// `WhatsAppPairParser`; refine alongside them once real `hermes whatsapp`
/// output is captured on the VPS.
struct WhatsAppPairParserTests {
    /// Drive the parser through a sequence of lines and collect every event.
    private func run(_ lines: [String]) -> [HermesWhatsAppPairEvent] {
        var parser = WhatsAppPairParser()
        var events: [HermesWhatsAppPairEvent] = []
        for line in lines { events += parser.consume(line: line) }
        events += parser.finish()
        return events
    }

    @Test func emitsQRFrameOnceBlockEnds() {
        let qrRows = Array(repeating: "█▀▀▀█ ▄▄ █▀▀▀█", count: 6)
        let events = run(["Scan this QR code:", ""] + qrRows + ["", "Waiting for scan…"])
        let qrs = events.compactMap { event -> String? in
            if case let .qr(art) = event { return art }
            return nil
        }
        #expect(qrs.count == 1)
        #expect(qrs[0].contains("█▀▀▀█"))
        // The QR rows must be joined with newlines, not collapsed.
        #expect(qrs[0].split(separator: "\n").count == 6)
    }

    @Test func ignoresShortBlockNoise() {
        // Fewer than the 5-row minimum → not treated as a QR.
        let events = run(["██", "██", "done"])
        #expect(!events.contains { if case .qr = $0 { return true } else { return false } })
    }

    @Test func detectsLinkedSuccess() {
        let events = run(["Device linked! You're all set."])
        #expect(events.contains(.linked))
    }

    @Test func detectsExpiry() {
        let events = run(["The QR code expired, generating a new one…"])
        #expect(events.contains(.status(.expired)))
    }

    @Test func detectsError() {
        let events = run(["Error: could not connect to WhatsApp"])
        guard case let .error(msg)? = events.first(where: { if case .error = $0 { return true } else { return false } }) else {
            Issue.record("expected an .error event")
            return
        }
        #expect(msg.lowercased().contains("could not connect"))
    }

    @Test func stripsANSIBeforeClassifying() {
        // A status line wrapped in colour escapes still classifies.
        let colored = "\u{1B}[32mDevice linked successfully\u{1B}[0m"
        #expect(run([colored]).contains(.linked))
    }

    @Test func ansiOnlyAndBlankLinesAreInert() {
        let events = run(["\u{1B}[2J", "\u{1B}[H", "   "])
        #expect(events.isEmpty)
    }

    @Test func emitsFreshQRFrameAfterRefresh() {
        let frame = Array(repeating: "█ █ █ █ █ █", count: 5)
        let events = run(frame + ["refreshing"] + frame + ["scan now"])
        let count = events.reduce(0) { acc, e in
            if case .qr = e { return acc + 1 } else { return acc }
        }
        #expect(count == 2)
    }
}
