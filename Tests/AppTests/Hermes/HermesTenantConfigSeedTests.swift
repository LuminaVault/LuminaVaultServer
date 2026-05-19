@testable import App
import Foundation
import Testing

/// HER-254 — `HermesTenantConfigTemplate.seed` writes a minimal `config.yaml`
/// + `.env` into the tenant's volume directory before docker spawn. Pure
/// filesystem operation — no DB/Docker required.
@Suite(.serialized)
struct HermesTenantConfigSeedTests {
    private static func makeTempVolume() throws -> String {
        let path = "\(NSTemporaryDirectory())lv-her254-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    private static func read(_ path: String) throws -> String {
        try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
    }

    @Test
    func `seed writes config and env with key`() throws {
        let volume = try Self.makeTempVolume()
        defer { _ = try? FileManager.default.removeItem(atPath: volume) }

        try HermesTenantConfigTemplate.seed(
            volumePath: volume,
            apiKey: "deadbeef-test-key",
            defaultModel: "hermes-3",
        )

        let configContent = try Self.read("\(volume)/.hermes/config.yaml")
        let envContent = try Self.read("\(volume)/.hermes/.env")

        #expect(configContent.contains("api_server:"))
        #expect(configContent.contains("enabled: true"))
        #expect(configContent.contains("host: 0.0.0.0"))
        #expect(configContent.contains("hermes-3"))
        // Other platforms must be disabled — the gateway will exit if any
        // enabled platform fails to connect.
        #expect(configContent.contains("telegram:"))
        #expect(configContent.contains("discord:"))
        #expect(configContent.contains("whatsapp:"))

        #expect(envContent.contains("API_SERVER_KEY=deadbeef-test-key"))
        #expect(envContent.contains("API_SERVER_HOST=0.0.0.0"))
    }

    @Test
    func `seed is idempotent on identical re-call`() async throws {
        let volume = try Self.makeTempVolume()
        defer { _ = try? FileManager.default.removeItem(atPath: volume) }

        try HermesTenantConfigTemplate.seed(volumePath: volume, apiKey: "stable", defaultModel: "hermes-3")
        let configPath = "\(volume)/.hermes/config.yaml"
        let firstMtime = try FileManager.default.attributesOfItem(atPath: configPath)[.modificationDate] as? Date

        try await Task.sleep(nanoseconds: 1_100_000_000)
        try HermesTenantConfigTemplate.seed(volumePath: volume, apiKey: "stable", defaultModel: "hermes-3")
        let secondMtime = try FileManager.default.attributesOfItem(atPath: configPath)[.modificationDate] as? Date

        #expect(firstMtime == secondMtime, "identical content must not trigger a rewrite")
    }

    @Test
    func `seed rewrites on drift`() async throws {
        let volume = try Self.makeTempVolume()
        defer { _ = try? FileManager.default.removeItem(atPath: volume) }

        try HermesTenantConfigTemplate.seed(volumePath: volume, apiKey: "k1", defaultModel: "hermes-3")

        let configPath = "\(volume)/.hermes/config.yaml"
        try "tampered".write(toFile: configPath, atomically: true, encoding: .utf8)
        let firstMtime = try FileManager.default.attributesOfItem(atPath: configPath)[.modificationDate] as? Date

        try await Task.sleep(nanoseconds: 1_100_000_000)
        try HermesTenantConfigTemplate.seed(volumePath: volume, apiKey: "k1", defaultModel: "hermes-3")
        let secondMtime = try FileManager.default.attributesOfItem(atPath: configPath)[.modificationDate] as? Date

        #expect(firstMtime != secondMtime, "drifted content must trigger a rewrite")
        let restored = try Self.read(configPath)
        #expect(restored.contains("api_server:"))
    }

    @Test
    func `seed rewrites when api key rotates`() throws {
        let volume = try Self.makeTempVolume()
        defer { _ = try? FileManager.default.removeItem(atPath: volume) }

        try HermesTenantConfigTemplate.seed(volumePath: volume, apiKey: "old-key", defaultModel: "hermes-3")
        let envPath = "\(volume)/.hermes/.env"
        #expect(try Self.read(envPath).contains("API_SERVER_KEY=old-key"))

        try HermesTenantConfigTemplate.seed(volumePath: volume, apiKey: "new-key", defaultModel: "hermes-3")
        #expect(try Self.read(envPath).contains("API_SERVER_KEY=new-key"))
        #expect(try !(Self.read(envPath).contains("old-key")))
    }
}
