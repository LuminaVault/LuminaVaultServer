@testable import App
import Foundation
import Testing

@Suite("Local memory sync cursor")
struct LocalMemorySyncCursorTests {
    @Test
    func `opaque cursor round trips every stable ordering field`() throws {
        let cursor = try LocalMemorySyncCursor(
            timestamp: Date(timeIntervalSince1970: 1_726_000_000.125),
            id: #require(UUID(uuidString: "aabbccdd-0000-4000-8000-000000000001")),
            kind: .deletion
        )

        let encoded = try cursor.encode()

        #expect(encoded.hasPrefix("v1."))
        #expect(try LocalMemorySyncCursor.decode(encoded) == cursor)
    }

    @Test
    func `legacy timestamp cursor remains accepted`() throws {
        let value = try LocalMemorySyncCursor.decode("2026-07-13T12:34:56Z")
        let decoded = try #require(value)

        #expect(decoded.timestamp == ISO8601DateFormatter().date(from: "2026-07-13T12:34:56Z"))
        #expect(decoded.kind == .memory)
    }

    @Test
    func `malformed opaque cursor is rejected`() {
        #expect(throws: LocalMemorySyncCursorError.self) {
            try LocalMemorySyncCursor.decode("v1.not-base64")
        }
    }
}
