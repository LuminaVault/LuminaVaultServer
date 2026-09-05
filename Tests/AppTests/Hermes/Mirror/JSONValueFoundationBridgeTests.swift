@testable import App
import Foundation
import LuminaVaultShared
import Testing

/// `JSONValue(foundation:)` bridges `JSONSerialization` output into the value
/// stored in `hermes_mirrored_jobs.raw`.
///
/// It distinguished booleans from numbers with `CFBooleanGetTypeID`, which is
/// Darwin-only: it compiled on macOS and broke the Linux build that CI runs.
/// The replacement reads the ObjC type encoding instead, and that has to
/// behave the same on both platforms — if it does not, a mirrored job's
/// `paused: true` silently becomes `1` and nothing else notices.
///
/// These are pure, so they run on Linux without Postgres.
@Suite("JSONValue foundation bridge")
struct JSONValueFoundationBridgeTests {
    private func bridged(_ json: String) throws -> JSONValue {
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8), options: [])
        return JSONValue(foundation: object)
    }

    @Test("booleans survive as booleans, not as 1 and 0")
    func booleansStayBooleans() throws {
        let value = try bridged(#"{"paused": true, "enabled": false}"#)
        guard case let .object(fields) = value else {
            Issue.record("expected an object, got \(value)")
            return
        }
        #expect(fields["paused"] == .bool(true))
        #expect(fields["enabled"] == .bool(false))
    }

    /// The inverse of the above, and the failure this guards: 1 and 0 are the
    /// values a boolean would be mistaken for.
    @Test("numbers stay numbers, including 1 and 0")
    func numbersStayNumbers() throws {
        let value = try bridged(#"{"one": 1, "zero": 0, "pi": 3.5, "big": 1756800000}"#)
        guard case let .object(fields) = value else {
            Issue.record("expected an object, got \(value)")
            return
        }
        #expect(fields["one"] == .number(1))
        #expect(fields["zero"] == .number(0))
        #expect(fields["pi"] == .number(3.5))
        #expect(fields["big"] == .number(1_756_800_000))
    }

    @Test("strings, null and nesting round-trip")
    func otherKinds() throws {
        let value = try bridged(#"{"name": "digest", "gone": null, "tags": ["a", 2, true]}"#)
        guard case let .object(fields) = value else {
            Issue.record("expected an object, got \(value)")
            return
        }
        #expect(fields["name"] == .string("digest"))
        #expect(fields["gone"] == .null)
        #expect(fields["tags"] == .array([.string("a"), .number(2), .bool(true)]))
    }

    /// A mirrored cron row is the shape this actually sees in production.
    @Test("a cron row keeps paused boolean and schedule string apart")
    func cronRowShape() throws {
        let value = try bridged(#"{"id":"digest","name":"Digest","paused":false,"schedule":"0 3 * * *","runs":12}"#)
        guard case let .object(fields) = value else {
            Issue.record("expected an object, got \(value)")
            return
        }
        #expect(fields["paused"] == .bool(false))
        #expect(fields["paused"] != .number(0))
        #expect(fields["schedule"] == .string("0 3 * * *"))
        #expect(fields["runs"] == .number(12))
    }
}
