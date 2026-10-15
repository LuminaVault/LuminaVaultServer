@testable import App
import FluentPostgresDriver
import Foundation
import Logging
import Testing

/// Boot used to trap when Postgres reset the first connection after the
/// migrate Job. These pin the retry to connection-level failures only.
struct StartupRetryTests {
    private actor Counter {
        var value = 0
        func next() -> Int {
            value += 1
            return value
        }
    }

    private struct NotAConnectionError: Error {}
    private struct DroppedConnection: Error {}
    private static let dropped: @Sendable (any Error) -> Bool = { $0 is DroppedConnection }

    private let logger = Logger(label: "test.startup.retry")

    @Test
    func `a dropped connection is retried until the work succeeds`() async throws {
        let calls = Counter()
        let result = try await StartupRetry.run("test", logger: logger, isTransient: Self.dropped, sleep: { _ in }) {
            if await calls.next() < 3 {
                throw DroppedConnection()
            }
            return "migrated"
        }
        #expect(result == "migrated")
        #expect(await calls.value == 3)
    }

    @Test
    func `any other error stops the boot on the first attempt`() async {
        let calls = Counter()
        await #expect(throws: NotAConnectionError.self) {
            try await StartupRetry.run("test", logger: logger, isTransient: Self.dropped, sleep: { _ in }) {
                _ = await calls.next()
                throw NotAConnectionError()
            }
        }
        #expect(await calls.value == 1)
    }

    @Test
    func `retries are bounded`() async {
        let calls = Counter()
        await #expect(throws: DroppedConnection.self) {
            try await StartupRetry.run(
                "test", delays: [.zero, .zero], logger: logger, isTransient: Self.dropped, sleep: { _ in }
            ) {
                _ = await calls.next()
                throw DroppedConnection()
            }
        }
        #expect(await calls.value == 3)
    }

    @Test
    func `only Postgres connection errors count as transient by default`() {
        #expect(!StartupRetry.isTransientConnectionError(NotAConnectionError()))
    }
}
