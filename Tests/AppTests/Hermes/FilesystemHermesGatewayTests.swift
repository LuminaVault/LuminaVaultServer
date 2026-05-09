import Foundation
import Logging
import Testing

@testable import App

@Suite
struct FilesystemHermesGatewayTests {
    private func makeGateway() -> (FilesystemHermesGateway, URL) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("lv-hermes-test-\(UUID().uuidString)", isDirectory: true)
        let gateway = FilesystemHermesGateway(rootPath: tmp.path, logger: Logger(label: "test.hermes"))
        return (gateway, tmp)
    }

    @Test
    func provisionsProfileDirectoryAndConfig() async throws {
        let (gw, root) = makeGateway()
        defer { try? FileManager.default.removeItem(at: root) }

        let tenant = UUID()
        let id = try await gw.provisionProfile(tenantID: tenant, username: "alice")
        #expect(id == "alice")

        let configURL = root.appendingPathComponent("profiles/alice/profile.json")
        #expect(FileManager.default.fileExists(atPath: configURL.path))

        let json = try JSONSerialization.jsonObject(with: try Data(contentsOf: configURL)) as? [String: Any]
        #expect(json?["username"] as? String == "alice")
        #expect(json?["tenantID"] as? String == tenant.uuidString)
        #expect(json?["schemaVersion"] as? Int == 1)
    }

    @Test
    func sameTenantSameUsernameIsIdempotent() async throws {
        let (gw, root) = makeGateway()
        defer { try? FileManager.default.removeItem(at: root) }

        let tenant = UUID()
        _ = try await gw.provisionProfile(tenantID: tenant, username: "bob")
        let second = try await gw.provisionProfile(tenantID: tenant, username: "bob")
        #expect(second == "bob")
    }

    @Test
    func differentTenantSameUsernameThrows() async throws {
        let (gw, root) = makeGateway()
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try await gw.provisionProfile(tenantID: UUID(), username: "carol")
        await #expect(throws: HermesGatewayError.self) {
            _ = try await gw.provisionProfile(tenantID: UUID(), username: "carol")
        }
    }

    @Test
    func deleteRenamesDir() async throws {
        let (gw, root) = makeGateway()
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try await gw.provisionProfile(tenantID: UUID(), username: "dave")
        try await gw.deleteProfile(hermesProfileID: "dave")

        let original = root.appendingPathComponent("profiles/dave")
        #expect(!FileManager.default.fileExists(atPath: original.path))

        let profilesRoot = root.appendingPathComponent("profiles")
        let entries = try FileManager.default.contentsOfDirectory(atPath: profilesRoot.path)
        #expect(entries.contains { $0.hasPrefix("_deleted_") && $0.hasSuffix("_dave") })
    }
}
