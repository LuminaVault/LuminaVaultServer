import Foundation

/// Incremental Server-Sent-Events record parser (WHATWG framing).
///
/// Feed raw text as it arrives; every complete record (terminated by a
/// blank line) comes back as `(event, data)`. `event:` is optional — Hermes'
/// `/v1/runs/{id}/events` puts the event name inside the JSON `data`
/// instead — multi-line `data:` fields are joined with `\n`, and comment
/// lines (`: keepalive`) are dropped. A trailing partial record is kept
/// until more bytes arrive; call `flush()` at end of stream to surface it.
struct SSEFrameParser: Sendable {
    struct Record: Equatable, Sendable {
        let event: String?
        let data: String
    }

    private var buffer = ""

    init() {}

    mutating func feed(_ text: String) -> [Record] {
        buffer.append(text)
        var records: [Record] = []
        while let terminator = Self.recordTerminator(in: buffer) {
            let raw = String(buffer[..<terminator.lowerBound])
            buffer.removeSubrange(..<terminator.upperBound)
            if let record = Self.parse(record: raw) {
                records.append(record)
            }
        }
        return records
    }

    /// Parse whatever is left (a record the upstream closed without the
    /// blank-line terminator).
    mutating func flush() -> Record? {
        defer { buffer = "" }
        return Self.parse(record: buffer)
    }

    /// Records end at the first blank line; accept `\n\n`, `\r\n\r\n` and
    /// the mixed forms.
    private static func recordTerminator(in text: String) -> Range<String.Index>? {
        var best: Range<String.Index>?
        for candidate in ["\r\n\r\n", "\n\n", "\r\r"] {
            guard let range = text.range(of: candidate) else { continue }
            if let current = best, current.lowerBound <= range.lowerBound {
                continue
            }
            best = range
        }
        return best
    }

    static func parse(record: String) -> Record? {
        var event: String?
        var dataLines: [String] = []
        for rawLine in record.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" }) {
            let line = String(rawLine).trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            if line.isEmpty || line.hasPrefix(":") {
                continue
            }
            let (field, value) = splitField(line)
            switch field {
            case "event": event = value
            case "data": dataLines.append(value)
            default: continue // `id:` / `retry:` are not used by Hermes
            }
        }
        guard !dataLines.isEmpty else { return nil }
        return Record(event: event, data: dataLines.joined(separator: "\n"))
    }

    private static func splitField(_ line: String) -> (String, String) {
        guard let colon = line.firstIndex(of: ":") else { return (line, "") }
        let field = String(line[..<colon])
        var value = String(line[line.index(after: colon)...])
        if value.hasPrefix(" ") {
            value.removeFirst()
        }
        return (field, value)
    }
}
