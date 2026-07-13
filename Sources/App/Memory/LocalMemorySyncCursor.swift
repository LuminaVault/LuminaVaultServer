import Foundation

struct LocalMemorySyncCursor: Codable, Equatable, Sendable {
    enum Kind: Int, Codable, Sendable {
        case memory
        case deletion
    }

    let timestamp: Date
    let id: UUID
    let kind: Kind

    func encode() throws -> String {
        let data = try JSONEncoder().encode(self)
        return "v1." + data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ raw: String?) throws -> LocalMemorySyncCursor? {
        guard let raw, !raw.isEmpty else { return nil }
        if raw.hasPrefix("v1.") {
            var encoded = String(raw.dropFirst(3))
                .replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/")
            encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
            guard let data = Data(base64Encoded: encoded) else {
                throw LocalMemorySyncCursorError.invalid
            }
            do {
                return try JSONDecoder().decode(Self.self, from: data)
            } catch {
                throw LocalMemorySyncCursorError.invalid
            }
        }

        // Backward compatibility for clients that persisted the original
        // timestamp-only cursor before stable pagination shipped.
        guard let timestamp = ISO8601DateFormatter().date(from: raw) else {
            throw LocalMemorySyncCursorError.invalid
        }
        return Self(
            timestamp: timestamp,
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
            kind: .memory
        )
    }
}

enum LocalMemorySyncCursorError: Error {
    case invalid
}

struct LocalMemorySyncEvent: Sendable {
    enum Payload: Sendable {
        case memory(Memory)
        case deletion(MemorySyncTombstone)
    }

    let cursor: LocalMemorySyncCursor
    let payload: Payload
}

extension LocalMemorySyncEvent {
    static func ordered(_ lhs: Self, _ rhs: Self) -> Bool {
        if lhs.cursor.timestamp != rhs.cursor.timestamp {
            return lhs.cursor.timestamp < rhs.cursor.timestamp
        }
        if lhs.cursor.id != rhs.cursor.id {
            return lhs.cursor.id.uuidString < rhs.cursor.id.uuidString
        }
        return lhs.cursor.kind.rawValue < rhs.cursor.kind.rawValue
    }
}
