@testable import App
import Foundation
import LuminaVaultShared
import Testing

@Suite("Marketplace safety validation", .disabled(if: IntegrationTestEnv.runIntegrationOnly))
struct MarketplaceSafetyTests {
    @Test("WASM versions require a valid, unique tool manifest")
    func validatesManifestTools() throws {
        let version = MarketplaceVersion()
        version.id = UUID()
        version.listingID = UUID()
        version.version = "1.0.0"
        version.status = MarketplaceVersionStatus.draft.rawValue
        version.runtimeKind = MarketplaceRuntimeKind.wasm.rawValue
        version.permissions = []
        version.networkHosts = []
        version.configFields = []
        version.artifactKey = "publisher/plugin/module.wasm"
        version.artifactSHA256 = String(repeating: "a", count: 64)
        version.manifestJSON = try JSONEncoder().encode(MarketplacePluginManifest(tools: [
            .init(name: "run", description: "Run safely"),
        ]))

        #expect(MarketplaceService.validate(version: version).isEmpty)
        #expect(try MarketplaceService.manifest(version).tools.map(\.name) == ["run"])
    }

    @Test("Duplicate and malformed tool names are rejected")
    func rejectsUnsafeTools() throws {
        let version = MarketplaceVersion()
        version.id = UUID()
        version.listingID = UUID()
        version.version = "1.0.0"
        version.status = MarketplaceVersionStatus.draft.rawValue
        version.runtimeKind = MarketplaceRuntimeKind.wasm.rawValue
        version.permissions = []
        version.networkHosts = []
        version.configFields = []
        version.artifactKey = "publisher/plugin/module.wasm"
        version.artifactSHA256 = String(repeating: "a", count: 64)
        version.manifestJSON = try JSONEncoder().encode(MarketplacePluginManifest(tools: [
            .init(name: "Bad Tool", description: "Unsafe"),
            .init(name: "Bad Tool", description: "Duplicate"),
        ]))

        let errors = MarketplaceService.validate(version: version)
        #expect(errors.contains("duplicate_plugin_tools"))
        #expect(errors.contains("invalid_plugin_tool_name"))
    }
}
