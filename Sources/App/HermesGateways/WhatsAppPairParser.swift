import Foundation
import LuminaVaultShared

/// Pure, testable parser that turns the line-by-line stdout of
/// `hermes whatsapp` (run under a PTY via `script`) into
/// `HermesWhatsAppPairEvent`s.
///
/// `hermes whatsapp` prints a Unicode block-art QR (qrcode-terminal style),
/// refreshing it roughly every 20s, interleaved with human status lines
/// ("Scan this QR…", "Linked!", "QR expired", …). Because it runs under a
/// pseudo-TTY the stream also carries ANSI escape sequences (colour, cursor
/// moves) which we strip before classifying a line.
///
/// Marker strings are centralised and matched case-insensitively with
/// `contains` so a wording change upstream is a one-line edit. They are an
/// informed default **pending a capture of real CLI output on the VPS** (the
/// pre-flight spike) — once the exact success/expiry wording is known, tighten
/// the marker arrays below.
struct WhatsAppPairParser {
    // Spike-refine: confirm against real `hermes whatsapp` output.
    static let linkedMarkers = [
        "linked", "connected", "successfully paired", "pairing complete",
        "logged in", "device linked", "you're all set",
    ]
    static let expiredMarkers = [
        "qr expired", "code expired", "expired", "timed out", "timeout",
    ]
    static let errorMarkers = [
        "error", "failed", "could not", "unable to", "disconnected",
    ]

    /// Glyphs qrcode-terminal uses to draw the QR. Whitespace counts as part of
    /// a QR row (quiet zone / white modules).
    private static let blockChars = Set("█▀▄▐▌░▒▓◼◻ \u{00A0}")

    private var qrBuffer: [String] = []

    /// Feed one raw stdout line; returns any events it produced.
    mutating func consume(line rawLine: String) -> [HermesWhatsAppPairEvent] {
        let line = Self.stripANSI(rawLine)

        if Self.isQRLine(line) {
            qrBuffer.append(line)
            return []
        }

        var events: [HermesWhatsAppPairEvent] = []
        // Any non-QR line closes an in-progress QR frame.
        if let qr = flushQR() {
            events.append(qr)
        }

        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return events }
        let lower = trimmed.lowercased()

        // Order matters: a line can read "failed to link" — treat explicit
        // error wording first, but don't fire on a success line that happens
        // to contain a benign word.
        if Self.errorMarkers.contains(where: lower.contains),
           !Self.linkedMarkers.contains(where: lower.contains)
        {
            events.append(.error(trimmed))
        } else if Self.linkedMarkers.contains(where: lower.contains) {
            events.append(.linked)
        } else if Self.expiredMarkers.contains(where: lower.contains) {
            events.append(.status(.expired))
        }
        return events
    }

    /// Flush any trailing QR frame when the stream ends.
    mutating func finish() -> [HermesWhatsAppPairEvent] {
        flushQR().map { [$0] } ?? []
    }

    private mutating func flushQR() -> HermesWhatsAppPairEvent? {
        defer { qrBuffer.removeAll(keepingCapacity: true) }
        // Require several rows so a stray block char isn't mistaken for a QR.
        guard qrBuffer.count >= 5 else { return nil }
        return .qr(qrBuffer.joined(separator: "\n"))
    }

    private static func isQRLine(_ line: String) -> Bool {
        let nonSpace = line.filter { !$0.isWhitespace }
        guard nonSpace.count >= 6 else { return false } // wide enough to be a QR row
        let blockCount = line.reduce(0) { $0 + (blockChars.contains($1) ? 1 : 0) }
        // Overwhelmingly block/space chars → it's a QR row, not prose.
        return Double(blockCount) / Double(line.count) >= 0.8
    }

    /// Strip ANSI CSI escape sequences (colour, cursor moves) emitted under the
    /// PTY. Carriage returns are already trimmed by the docker `LineBuffer`.
    static func stripANSI(_ s: String) -> String {
        guard s.contains("\u{1B}") else { return s }
        var out = ""
        out.reserveCapacity(s.count)
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "\u{1B}" {
                var j = s.index(after: i)
                if j < s.endIndex, s[j] == "[" {
                    j = s.index(after: j)
                }
                // CSI runs until a final byte in @A–Z[a–z~ range.
                while j < s.endIndex, !Self.isCSIFinal(s[j]) {
                    j = s.index(after: j)
                }
                if j < s.endIndex {
                    j = s.index(after: j)
                } // consume final byte
                i = j
            } else {
                out.append(s[i])
                i = s.index(after: i)
            }
        }
        return out
    }

    private static func isCSIFinal(_ c: Character) -> Bool {
        c.isLetter || c == "~" || c == "@"
    }
}
