import Crypto
import Foundation

/// Harvests images, files and links from Hermes session messages — the same
/// shapes Hermes Desktop's artifacts gallery uses (`artifact-utils.ts`).
///
/// Pure: no I/O. The collect pass feeds it session rows the gateway already
/// listed, then upserts the records. Local VPS paths are stored as `file`
/// records; preview bytes are a later dashboard concern.
enum HermesArtifactExtractor {
    enum Kind: String, Sendable {
        case image
        case file
        case link
    }

    struct Record: Sendable, Equatable {
        let kind: Kind
        let value: String
        let href: String
        let label: String
        let sessionID: String
        let sessionTitle: String
        let occurredAt: Date
        let contentHash: String
    }

    static func extract(
        sessionID: String,
        sessionTitle: String,
        sessionTimestamp: Date?,
        messages: [HermesMirrorSessionMessage]
    ) -> [Record] {
        var found: [String: Record] = [:]
        let title = sessionTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackTitle = title.isEmpty ? "Untitled session" : title

        for message in messages {
            guard message.role == "assistant" || message.role == "tool" else { continue }
            let occurred = message.timestamp ?? sessionTimestamp ?? Date(timeIntervalSince1970: 0)
            collect(from: message.content) { candidate in
                let value = normalize(candidate)
                guard !value.isEmpty, looksLikeArtifact(value) else { return }
                let key = "\(sessionID):\(value)"
                guard found[key] == nil else { return }
                let kind = kind(of: value)
                found[key] = Record(
                    kind: kind,
                    value: value,
                    href: href(for: value),
                    label: label(for: value),
                    sessionID: sessionID,
                    sessionTitle: fallbackTitle,
                    occurredAt: occurred,
                    contentHash: hash(kind: kind, value: value, sessionID: sessionID)
                )
            }
        }
        return found.values.sorted { $0.occurredAt > $1.occurredAt }
    }

    static func hash(kind: Kind, value: String, sessionID: String) -> String {
        let payload = "\(kind.rawValue)|\(value)|\(sessionID)"
        let digest = SHA256.hash(data: Data(payload.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Collection

    static func collect(from text: String, push: (String) -> Void) {
        enumerate(text, pattern: #"!\[(?:[^\]]*)\]\(([^)\s]+)\)"#, group: 1, push)
        enumerate(text, pattern: #"\[(?:[^\]]+)\]\(([^)\s]+)\)"#, group: 1) { value in
            if looksLikeArtifact(value) { push(value) }
        }
        enumerate(text, pattern: #"https?://[^\s<>"')]+"#, group: 0) { value in
            if looksLikeArtifact(value) { push(value) }
        }
        enumerate(text, pattern: #"(?:^|[\s("'`])((?:/|~/|\.\.?/)[^\s"'`<>]+(?:\.[A-Za-z0-9]{1,8})?)"#, group: 1, push)
        if let parsed = parseJSON(text) {
            collectStrings(parsed, keyPath: "tool_result") { value, keyPath in
                let normalized = normalize(value)
                guard !normalized.isEmpty else { return }
                if (keyHint.contains(where: { keyPath.localizedCaseInsensitiveContains($0) }) || looksLikePathOrURL(normalized)),
                   looksLikeArtifact(normalized)
                {
                    push(normalized)
                }
            }
        }
    }

    private static func enumerate(_ text: String, pattern: String, group: Int, _ push: (String) -> Void) {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        regex.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match else { return }
            let capture = group == 0 ? match.range : match.range(at: group)
            guard capture.location != NSNotFound else { return }
            push(ns.substring(with: capture))
        }
    }

    // MARK: - Classification

    static func kind(of value: String) -> Kind {
        if value.hasPrefix("data:image/") || imageExt.contains(where: { value.lowercased().contains($0) }) {
            return .image
        }
        if value.hasPrefix("/") || value.hasPrefix("./") || value.hasPrefix("../")
            || value.hasPrefix("~/") || value.hasPrefix("file://")
        {
            return .file
        }
        return .link
    }

    static func href(for value: String) -> String {
        if value.hasPrefix("http://") || value.hasPrefix("https://") || value.hasPrefix("data:") {
            return value
        }
        return value
    }

    static func label(for value: String) -> String {
        if let url = URL(string: value), let host = url.host {
            let item = url.path.split(separator: "/").last.map(String.init)
            return item?.isEmpty == false ? item! : host
        }
        return value.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? value
    }

    static func looksLikeArtifact(_ value: String) -> Bool {
        if value.hasPrefix("http://") || value.hasPrefix("https://") || value.hasPrefix("data:image/") {
            return true
        }
        if looksLikePathOrURL(value), imageExt.contains(where: { value.lowercased().contains($0) })
            || fileExt.contains(where: { value.lowercased().contains($0) })
        {
            return true
        }
        return value.hasPrefix("/") && value.contains(".")
    }

    static func looksLikePathOrURL(_ value: String) -> Bool {
        value.hasPrefix("http://") || value.hasPrefix("https://") || value.hasPrefix("file://")
            || value.hasPrefix("data:image/") || value.hasPrefix("/") || value.hasPrefix("./")
            || value.hasPrefix("../") || value.hasPrefix("~/")
    }

    static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "),.;"))
    }

    // MARK: - JSON walk

    private static func parseJSON(_ text: String) -> Any? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") || trimmed.hasPrefix("[") else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))
    }

    private static func collectStrings(_ value: Any, keyPath: String, into: (String, String) -> Void) {
        if let string = value as? String {
            into(string, keyPath)
            return
        }
        if let array = value as? [Any] {
            for (index, child) in array.enumerated() {
                collectStrings(child, keyPath: "\(keyPath).\(index)", into: into)
            }
            return
        }
        if let object = value as? [String: Any] {
            for (key, child) in object {
                collectStrings(child, keyPath: keyPath.isEmpty ? key : "\(keyPath).\(key)", into: into)
            }
        }
    }

    private static let imageExt = [".png", ".jpg", ".jpeg", ".gif", ".webp", ".svg", ".bmp"]
    private static let fileExt = [
        ".png", ".jpg", ".jpeg", ".gif", ".webp", ".svg", ".bmp",
        ".pdf", ".txt", ".json", ".md", ".csv", ".zip", ".tar", ".gz",
        ".mp3", ".wav", ".mp4", ".mov",
    ]
    private static let keyHint = ["path", "file", "url", "image", "artifact", "output", "download", "result", "target"]
}
