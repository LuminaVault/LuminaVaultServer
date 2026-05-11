import Foundation
import Logging
import Testing

@testable import App

/// HER-85: SOUL.md service unit tests. Filesystem-only — no DB required.
@Suite(.serialized)
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
    func readReturnsDefaultTemplateWhenFileAbsent() throws {
        let h = Self.makeHarness()
        let body = try h.service.read(for: h.user)
        #expect(body.contains("# SOUL.md"))
    }

    @Test
    func writeRoundTripsThroughRead() throws {
        let h = Self.makeHarness()
        let payload = "# Personal SOUL\n\nHello, world.\n"
        try h.service.write(for: h.user, body: payload)
        let read = try h.service.read(for: h.user)
        #expect(read == payload)
    }

    @Test
    func writeMirrorsToBothVaultAndHermesProfilePaths() throws {
        let h = Self.makeHarness()
        let payload = "# Mirror Test\n"
        try h.service.write(for: h.user, body: payload)

        let tenantID = try h.user.requireID()
        let vaultFile = h.vaultRoot
            .appendingPathComponent("tenants").appendingPathComponent(tenantID.uuidString)
            .appendingPathComponent("raw").appendingPathComponent("SOUL.md")
        let hermesFile = h.hermesRoot
            .appendingPathComponent("profiles").appendingPathComponent(h.user.username)
            .appendingPathComponent("SOUL.md")

        let vaultData = try String(contentsOf: vaultFile, encoding: .utf8)
        let hermesData = try String(contentsOf: hermesFile, encoding: .utf8)
        #expect(vaultData == payload)
        #expect(hermesData == payload)
    }

    @Test
    func writeRejectsBodyAbove64KiB() throws {
        let h = Self.makeHarness()
        let oversized = String(repeating: "x", count: SOULService.maxSizeBytes + 1)
        do {
            try h.service.write(for: h.user, body: oversized)
            Issue.record("expected SOULServiceError.tooLarge")
        } catch SOULServiceError.tooLarge(let bytes, let limit) {
            #expect(bytes == SOULService.maxSizeBytes + 1)
            #expect(limit == SOULService.maxSizeBytes)
        }
    }

    @Test
    func writeAcceptsBodyAtExactly64KiB() throws {
        let h = Self.makeHarness()
        let atLimit = String(repeating: "x", count: SOULService.maxSizeBytes)
        try h.service.write(for: h.user, body: atLimit)
        let read = try h.service.read(for: h.user)
        #expect(read.count == SOULService.maxSizeBytes)
    }

    @Test
    func resetWritesDefaultTemplateAndOverwritesPriorContent() throws {
        let h = Self.makeHarness()
        try h.service.write(for: h.user, body: "# Custom\n")
        let reset = try h.service.reset(for: h.user)
        #expect(reset.contains("# SOUL.md"))
        let read = try h.service.read(for: h.user)
        #expect(read == reset)
    }

    @Test
    func writeIsAtomicNoTmpFilesLeftBehind() throws {
        let h = Self.makeHarness()
        try h.service.write(for: h.user, body: "first\n")
        try h.service.write(for: h.user, body: "second\n")
        let tenantID = try h.user.requireID()
        let rawDir = h.vaultRoot
            .appendingPathComponent("tenants").appendingPathComponent(tenantID.uuidString)
            .appendingPathComponent("raw")
        let entries = try FileManager.default.contentsOfDirectory(atPath: rawDir.path)
        // Only the final SOUL.md should remain — no `.tmp-*` artifacts.
        #expect(entries == ["SOUL.md"])
    }

    @Test
    func initIfMissingDoesNotOverwriteExistingFile() throws {
        let h = Self.makeHarness()
        try h.service.write(for: h.user, body: "# Custom\n")
        let wrote = try h.service.initIfMissing(for: h.user)
        #expect(wrote == false)
        let read = try h.service.read(for: h.user)
        #expect(read == "# Custom\n")
    }
}
