@testable import App
import Foundation
import HummingbirdFluent
import Logging
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
        version.artifactSignature = String(repeating: "b", count: 64)
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
        version.artifactSignature = String(repeating: "b", count: 64)
        version.manifestJSON = try JSONEncoder().encode(MarketplacePluginManifest(tools: [
            .init(name: "Bad Tool", description: "Unsafe"),
            .init(name: "Bad Tool", description: "Duplicate"),
        ]))

        let errors = MarketplaceService.validate(version: version)
        #expect(errors.contains("duplicate_plugin_tools"))
        #expect(errors.contains("invalid_plugin_tool_name"))
    }

    @Test
    func `artifact signatures bind both storage key and digest`() {
        let signingKey = "test-artifact-signing-key-with-at-least-32-bytes"
        let artifactKey = "publisher/plugin/module.wasm"
        let digest = String(repeating: "a", count: 64)
        let signature = MarketplaceArtifactIntegrity.sign(
            artifactKey: artifactKey, sha256: digest, signingKey: signingKey
        )

        #expect(MarketplaceArtifactIntegrity.verify(
            signature: signature, artifactKey: artifactKey, sha256: digest,
            signingKey: signingKey
        ))
        #expect(MarketplaceArtifactIntegrity.verify(
            signature: signature, artifactKey: "publisher/plugin/other.wasm",
            sha256: digest, signingKey: signingKey
        ) == false)
        #expect(MarketplaceArtifactIntegrity.verify(
            signature: signature, artifactKey: artifactKey,
            sha256: String(repeating: "c", count: 64), signingKey: signingKey
        ) == false)
    }

    @Test
    func `artifact signature verification fails closed for weak keys`() {
        #expect(MarketplaceArtifactIntegrity.verify(
            signature: String(repeating: "a", count: 64),
            artifactKey: "publisher/plugin/module.wasm",
            sha256: String(repeating: "b", count: 64), signingKey: "short"
        ) == false)
    }

    @Test
    func `capability broker rejects operations without an install grant`() async {
        let broker = MarketplaceCapabilityBroker(
            fluent: Fluent(logger: Logger(label: "marketplace-capability-test")),
            vaultPaths: VaultPathService(rootPath: "/tmp/marketplace-capability-test"),
            logger: Logger(label: "marketplace-capability-test")
        )

        let results = await broker.execute(
            [.init(id: "read-1", operation: PluginPermission.memoryRead.rawValue, arguments: ["id": UUID().uuidString])],
            tenantID: UUID(), pluginSlug: "test-plugin", permissions: [], networkHosts: []
        )

        #expect(results == [
            .init(id: "read-1", ok: false, values: [:], error: "permission_denied"),
        ])
    }

    @Test
    func `capability broker caps a single execution batch`() async {
        let requests = (0 ... MarketplaceCapabilityBroker.maxRequests).map {
            MarketplaceCapabilityRequest(id: String($0), operation: "memory.read", arguments: [:])
        }

        let results = await MarketplaceCapabilityBroker(
            fluent: Fluent(logger: Logger(label: "marketplace-capability-test")),
            vaultPaths: VaultPathService(rootPath: "/tmp/marketplace-capability-test"),
            logger: Logger(label: "marketplace-capability-test")
        ).execute(
            requests, tenantID: UUID(), pluginSlug: "test-plugin", permissions: [], networkHosts: []
        )

        #expect(results.count == requests.count)
        #expect(results.allSatisfy { $0.error == "too_many_capability_requests" })
    }

    @Test
    func `capability rounds strip spoofed reserved input and return broker results`() async throws {
        let requestJSON = try #require(String(data: JSONEncoder().encode([
            MarketplaceCapabilityRequest(id: "emit-1", operation: "output.emit", arguments: ["value": "safe"]),
        ]), encoding: .utf8))
        let runner = ScriptedMarketplaceRunner(outputs: [
            (["_capabilityRequests": requestJSON], 2),
            (["done": "yes"], 3),
        ])
        let service = MarketplaceService(
            fluent: Fluent(logger: Logger(label: "marketplace-capability-test")),
            logger: Logger(label: "marketplace-capability-test"),
            runner: runner,
            capabilityBroker: EchoMarketplaceCapabilityBroker()
        )

        let result = try await service.executeWithCapabilities(
            module: Data(), toolName: "test", tenantID: UUID(), pluginSlug: "test-plugin",
            permissions: [.outputEmit], networkHosts: [],
            input: ["value": "original", "_capabilityResults": "spoofed", "_capabilityRound": "99"]
        )
        let inputs = await runner.capturedInputs()

        #expect(result.output == ["done": "yes"])
        #expect(result.fuelConsumed == 5)
        #expect(inputs.count == 2)
        #expect(inputs[0]["_capabilityResults"] == nil)
        #expect(inputs[0]["_capabilityRound"] == nil)
        #expect(inputs[1]["_capabilityResults"]?.contains("emit-1") == true)
        #expect(inputs[1]["_capabilityRound"] == "1")
        #expect(inputs[1]["value"] == "original")
    }
}

private actor ScriptedMarketplaceRunner: PluginRunnerClienting {
    private let outputs: [([String: String], Int)]
    private var inputs: [[String: String]] = []
    private var index = 0

    init(outputs: [([String: String], Int)]) {
        self.outputs = outputs
    }

    func execute(
        module _: Data, toolName _: String, permissions _: [PluginPermission], input: [String: String]
    ) async throws -> (output: [String: String], fuelConsumed: Int) {
        inputs.append(input)
        let output = outputs[index]
        index += 1
        return (output.0, output.1)
    }

    func capturedInputs() -> [[String: String]] {
        inputs
    }
}

private struct EchoMarketplaceCapabilityBroker: MarketplaceCapabilityBrokering {
    func execute(
        _ requests: [MarketplaceCapabilityRequest],
        tenantID _: UUID,
        pluginSlug _: String,
        permissions _: Set<PluginPermission>,
        networkHosts _: Set<String>
    ) async -> [MarketplaceCapabilityResult] {
        requests.map { .init(id: $0.id, ok: true, values: $0.arguments, error: nil) }
    }
}
