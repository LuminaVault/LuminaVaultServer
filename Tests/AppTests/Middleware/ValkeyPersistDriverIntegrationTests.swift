@testable import App
import Foundation
import Hummingbird
import Logging
import Testing

private enum ValkeyIntegrationEnv {
    static let url = ProcessInfo.processInfo.environment["VALKEY_INTEGRATION_URL"]
    static let skip = url?.isEmpty != false
}

@Suite(.serialized, .disabled(if: ValkeyIntegrationEnv.skip))
struct ValkeyPersistDriverIntegrationTests {
    @Test
    func `valkey persist driver stores reads expires and removes`() async throws {
        let url = try #require(ValkeyIntegrationEnv.url)
        let logger = Logger(label: "test.valkey-persist")
        let driver = try ValkeyPersistDriver(
            configuration: ValkeyPersistConfiguration(url: url),
            namespace: "lv:test:\(UUID().uuidString)",
            logger: logger
        )
        let service = Task { try await driver.run() }
        defer { service.cancel() }

        try await driver.create(key: "duplicate", value: "first", expires: .seconds(5))
        await #expect(throws: PersistError.duplicate) {
            try await driver.create(key: "duplicate", value: "second", expires: .seconds(5))
        }

        try await driver.set(key: "short-lived", value: "value", expires: .milliseconds(150))
        let beforeExpiry = try await driver.get(key: "short-lived", as: String.self)
        #expect(beforeExpiry == "value")

        try await Task.sleep(for: .milliseconds(300))
        let afterExpiry = try await driver.get(key: "short-lived", as: String.self)
        #expect(afterExpiry == nil)

        try await driver.set(key: "remove-me", value: 42, expires: .seconds(5))
        try await driver.remove(key: "remove-me")
        let removed = try await driver.get(key: "remove-me", as: Int.self)
        #expect(removed == nil)
    }
}
