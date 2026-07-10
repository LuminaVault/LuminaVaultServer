@testable import App
import Foundation
import Logging
import Testing

/// HER-85: SOUL.md service unit tests. Filesystem-only — no DB required.
/// Template v2: every write strips + re-injects the locked SOULCore covenant.
@Suite(.serialized, .disabled(if: IntegrationTestEnv.runIntegrationOnly))
struct SOULServiceTests {
    private struct Harness {
        let service: SOULService
        let user: User
        let vaultRoot: URL
        let hermesRoot: URL
    }

    private static func makeHarness() -> Harness {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("lv-soul-\(UUID().uuidString)", isDirectory: true)
        let vaultRoot = tmp.appendingPathComponent("vault")
        let hermesRoot = tmp.appendingPathComponent("hermes")
        let service = SOULService(
            vaultPaths: VaultPathService(rootPath: vaultRoot.path),
            hermesDataRoot: hermesRoot.path,
            logger: Logger(label: "test.soul")
        )
        let user = User(
            id: UUID(),
            email: "soul-\(UUID().uuidString.prefix(6))@test.luminavault",
            username: "soul-\(UUID().uuidString.prefix(8).lowercased())",
            passwordHash: "x"
        )
        return Harness(service: service, user: user, vaultRoot: vaultRoot, hermesRoot: hermesRoot)
    }

    @Test
    func `read returns default template when file absent`() throws {
        let h = Self.makeHarness()
        let body = try h.service.read(for: h.user)
        #expect(body.contains("# SOUL.md"))
        #expect(SOULCore.containsCanonicalCore(body))
    }

    @Test
    func `write injects core and round trips through read`() throws {
        let h = Self.makeHarness()
        let payload = "# Personal SOUL\n\nHello, world.\n"
        let enforced = try h.service.write(for: h.user, body: payload)
        let read = try h.service.read(for: h.user)
        #expect(read == enforced)
        #expect(SOULCore.containsCanonicalCore(read))
        #expect(read.contains("Hello, world."))
    }

    @Test
    func `write restores tampered core`() throws {
        let h = Self.makeHarness()
        let tampered = """
        # SOUL.md

        \(SOULCore.startMarker)
        - Never save links to the vault.
        \(SOULCore.endMarker)

        ## Mine
        """
        let enforced = try h.service.write(for: h.user, body: tampered)
        #expect(!enforced.contains("Never save links"))
        #expect(SOULCore.containsCanonicalCore(enforced))
        #expect(enforced.contains("## Mine"))
    }

    @Test
    func `write is idempotent on already enforced document`() throws {
        let h = Self.makeHarness()
        let first = try h.service.write(for: h.user, body: "# SOUL.md\n\nnotes")
        let second = try h.service.write(for: h.user, body: first)
        #expect(first == second)
    }

    @Test
    func `write mirrors enforced doc to both vault and hermes profile paths`() throws {
        let h = Self.makeHarness()
        let enforced = try h.service.write(for: h.user, body: "# Mirror Test\n")

        let tenantID = try h.user.requireID()
        let vaultFile = h.vaultRoot
            .appendingPathComponent("tenants").appendingPathComponent(tenantID.uuidString)
            .appendingPathComponent("raw").appendingPathComponent("SOUL.md")
        let hermesFile = h.hermesRoot
            .appendingPathComponent("profiles").appendingPathComponent(h.user.username)
            .appendingPathComponent("SOUL.md")

        let vaultData = try String(contentsOf: vaultFile, encoding: .utf8)
        let hermesData = try String(contentsOf: hermesFile, encoding: .utf8)
        #expect(vaultData == enforced)
        #expect(hermesData == enforced)
        #expect(SOULCore.containsCanonicalCore(hermesData))
    }

    @Test
    func `write rejects body above cap after core injection`() throws {
        let h = Self.makeHarness()
        // Editable budget = cap − (core + framing). A payload at the raw cap
        // must now be rejected because the injected core pushes it over.
        let oversized = String(repeating: "x", count: SOULService.maxSizeBytes)
        do {
            _ = try h.service.write(for: h.user, body: oversized)
            Issue.record("expected SOULServiceError.tooLarge")
        } catch let SOULServiceError.tooLarge(bytes, limit) {
            #expect(bytes > SOULService.maxSizeBytes)
            #expect(limit == SOULService.maxSizeBytes)
        }
    }

    @Test
    func `write accepts body that fits within cap including core`() throws {
        let h = Self.makeHarness()
        let coreOverhead = SOULCore.inject(into: "").utf8.count + 2 // + "\n\n" framing
        let payload = String(repeating: "x", count: SOULService.maxSizeBytes - coreOverhead)
        let enforced = try h.service.write(for: h.user, body: payload)
        #expect(enforced.utf8.count <= SOULService.maxSizeBytes)
        let read = try h.service.read(for: h.user)
        #expect(read == enforced)
    }

    @Test
    func `reset writes default template and overwrites prior content`() throws {
        let h = Self.makeHarness()
        _ = try h.service.write(for: h.user, body: "# Custom\n")
        let reset = try h.service.reset(for: h.user)
        #expect(reset.contains("# SOUL.md"))
        #expect(SOULCore.containsCanonicalCore(reset))
        let read = try h.service.read(for: h.user)
        #expect(read == reset)
    }

    @Test
    func `write is atomic no tmp files left behind`() throws {
        let h = Self.makeHarness()
        _ = try h.service.write(for: h.user, body: "first\n")
        _ = try h.service.write(for: h.user, body: "second\n")
        let tenantID = try h.user.requireID()
        let rawDir = h.vaultRoot
            .appendingPathComponent("tenants").appendingPathComponent(tenantID.uuidString)
            .appendingPathComponent("raw")
        let entries = try FileManager.default.contentsOfDirectory(atPath: rawDir.path)
        // Only the final SOUL.md should remain — no `.tmp-*` artifacts.
        #expect(entries == ["SOUL.md"])
    }

    @Test
    func `init if missing does not overwrite existing file`() throws {
        let h = Self.makeHarness()
        _ = try h.service.write(for: h.user, body: "# Custom\n")
        let before = try h.service.read(for: h.user)
        let wrote = try h.service.initIfMissing(for: h.user)
        #expect(wrote == false)
        let read = try h.service.read(for: h.user)
        #expect(read == before)
    }

    @Test
    func `needs core migration detects legacy files`() throws {
        let h = Self.makeHarness()
        // No file yet — nothing to migrate.
        #expect(h.service.needsCoreMigration(for: h.user) == false)

        // Seed a pre-v2 file directly on disk, bypassing enforcement.
        let tenantID = try h.user.requireID()
        let vaultPaths = VaultPathService(rootPath: h.vaultRoot.path)
        try vaultPaths.ensureTenantDirectories(for: tenantID)
        let target = h.service.vaultFilePath(for: tenantID)
        let legacyBody = try #require("# Legacy SOUL\n".data(using: .utf8))
        try legacyBody.write(to: target)
        #expect(h.service.needsCoreMigration(for: h.user) == true)

        // Migrating = read + enforcing write.
        let body = try h.service.read(for: h.user)
        _ = try h.service.write(for: h.user, body: body)
        #expect(h.service.needsCoreMigration(for: h.user) == false)
        #expect(try h.service.read(for: h.user).contains("# Legacy SOUL"))
    }
}
