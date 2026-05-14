import Foundation

/// HER-200 L1 — guard that decides whether an inbound WebSocket text frame
/// is safe to fan out to peer connections. Pure function so it's unit-test
/// friendly and the call site in `buildRouter` can stay short.
///
/// Rejection reasons are surfaced as enum cases so callers can log a
/// specific reason rather than a boolean.
enum WebSocketBroadcastGuard {
    /// Maximum bytes a single broadcast message may contain. 16 KB chosen
    /// to comfortably hold a typed payload + small JSON envelope without
    /// letting a compromised client tunnel arbitrary blobs through the
    /// fan-out path.
    static let maxMessageBytes = 16 * 1024

    enum Decision: Equatable {
        case allow
        case rejectEmpty
        case rejectOversize(byteCount: Int)
        case rejectInvalidJSON
        case rejectMissingType
    }

    /// Inspect a raw text frame; return `.allow` only when:
    ///   * non-empty,
    ///   * within `maxMessageBytes`,
    ///   * parseable JSON,
    ///   * top-level object with a `type` field of type `String`.
    static func evaluate(_ message: String) -> Decision {
        if message.isEmpty {
            return .rejectEmpty
        }
        let byteCount = message.utf8.count
        if byteCount > maxMessageBytes {
            return .rejectOversize(byteCount: byteCount)
        }
        guard let data = message.data(using: .utf8) else {
            return .rejectInvalidJSON
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .rejectInvalidJSON
        }
        guard json["type"] is String else {
            return .rejectMissingType
        }
        return .allow
    }
}
