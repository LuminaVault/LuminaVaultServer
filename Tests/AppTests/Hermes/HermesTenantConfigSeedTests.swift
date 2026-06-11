@testable import App
import Foundation
import Testing

/// HER-254 — `HermesTenantConfigTemplate.seed` writes a minimal `config.yaml`
/// + `.env` into the tenant's volume directory before docker spawn. Pure
/// filesystem operation — no DB/Docker required.
///
/// Both files are written at the **volume root** (`/opt/data/config.yaml`,
/// `/opt/data/.env`) — the only paths Hermes reads via `get_config_path()` /
/// `get_env_path()`. (A prior version wrote under `.hermes/`, which Hermes
/// never reads — these tests assert the corrected root paths.)
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
    func `seed writes config and env at volume root`() throws {
        let volume = try Self.makeTempVolume()
        defer { _ = try? FileManager.default.removeItem(atPath: volume) }

        try HermesTenantConfigTemplate.seed(
            volumePath: volume,
            apiKey: "deadbeef-test-key",
            defaultModel: "hermes-3"
        )

        let configContent = try Self.read("\(volume)/config.yaml")
        let envContent = try Self.read("\(volume)/.env")

        #expect(configContent.contains("api_server:"))
        #expect(configContent.contains("enabled: true"))
        #expect(configContent.contains("host: 0.0.0.0"))
        #expect(configContent.contains("hermes-3"))
        // Messaging platforms are NOT listed in config.yaml — activation is
        // env-var driven (see HermesGatewayCatalog). Listing them would only
        // risk the gateway exiting on an unconfigured platform.
        #expect(!configContent.contains("telegram:"))
        #expect(!configContent.contains("discord:"))
        #expect(!configContent.contains("whatsapp:"))

        #expect(envContent.contains("API_SERVER_KEY=deadbeef-test-key"))
        #expect(envContent.contains("API_SERVER_HOST=0.0.0.0"))
    }

    @Test
    func `seed is idempotent on identical re-call`() async throws {
        let volume = try Self.makeTempVolume()
        defer { _ = try? FileManager.default.removeItem(atPath: volume) }

        try HermesTenantConfigTemplate.seed(volumePath: volume, apiKey: "stable", defaultModel: "hermes-3")
        let configPath = "\(volume)/config.yaml"
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

        let configPath = "\(volume)/config.yaml"
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
        let envPath = "\(volume)/.env"
        #expect(try Self.read(envPath).contains("API_SERVER_KEY=old-key"))

        try HermesTenantConfigTemplate.seed(volumePath: volume, apiKey: "new-key", defaultModel: "hermes-3")
        #expect(try Self.read(envPath).contains("API_SERVER_KEY=new-key"))
        #expect(try !(Self.read(envPath).contains("old-key")))
    }

    // MARK: - Mnemosyne default-memory wiring

    /// When Mnemosyne is enabled (the managed default) the config seeds the
    /// `mcp_servers.mnemosyne` block AND disables Hermes' native curated
    /// memory (`memory_enabled` / `user_profile_enabled`) so Mnemosyne is the
    /// single memory layer rather than competing with MEMORY.md/USER.md.
    @Test
    func `configYAML wires mnemosyne and disables native memory when enabled`() {
        let yaml = HermesTenantConfigTemplate.configYAML(defaultModel: "hermes-3", mnemosyneEnabled: true)

        #expect(yaml.contains("mcp_servers:"))
        #expect(yaml.contains("mnemosyne:"))
        #expect(yaml.contains("MNEMOSYNE_DATA_DIR: /opt/data/mnemosyne"))
        #expect(yaml.contains("FASTEMBED_CACHE_PATH: /opt/data/mnemosyne/cache"))
        // Native persistent memory disabled — Mnemosyne is the sole store.
        #expect(yaml.contains("memory_enabled: false"))
        #expect(yaml.contains("user_profile_enabled: false"))
    }

    /// When disabled, neither the Mnemosyne MCP block nor the native-memory
    /// override is emitted — Hermes falls back to its built-in file memory.
    @Test
    func `configYAML omits mnemosyne and leaves native memory when disabled`() {
        let yaml = HermesTenantConfigTemplate.configYAML(defaultModel: "hermes-3", mnemosyneEnabled: false)

        #expect(!yaml.contains("mnemosyne"))
        #expect(!yaml.contains("memory_enabled: false"))
        // api_server still configured regardless of the memory toggle.
        #expect(yaml.contains("api_server:"))
    }
}
