@testable import App
import Foundation
import Logging
import Testing

@Suite(.serialized, .disabled(if: IntegrationTestEnv.runIntegrationOnly))
struct HermesDataPathServiceTests {
    @Test
    func `ensure creates profiles and accepts writes`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lv-hermes-paths-\(UUID().uuidString)", isDirectory: true)
        let service = HermesDataPathService(hermesDataRoot: root.path)
        let logger = Logger(label: "test.hermes.paths")

        try service.ensureProfilesDirectoryWritable(logger: logger)

        let profiles = service.profilesRoot()
        #expect(FileManager.default.fileExists(atPath: profiles.path))

        let probe = profiles.appendingPathComponent("alice")
        try FileManager.default.createDirectory(at: probe, withIntermediateDirectories: true)
        try "ok".write(to: probe.appendingPathComponent("SOUL.md"), atomically: true, encoding: .utf8)
    }

    /// root ignores POSIX permission bits, so a chmod-based deny can never
    /// trip in the CI container (which runs as root) — skip there.
    @Test(.enabled(if: geteuid() != 0))
    func `ensure fails when profiles is not writable`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lv-hermes-paths-deny-\(UUID().uuidString)", isDirectory: true)
        let profiles = root.appendingPathComponent("profiles", isDirectory: true)
        try FileManager.default.createDirectory(at: profiles, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: profiles.path)

        let service = HermesDataPathService(hermesDataRoot: root.path)
        let logger = Logger(label: "test.hermes.paths")

        do {
            try service.ensureProfilesDirectoryWritable(logger: logger)
            Issue.record("expected HermesDataError.notWritable")
        } catch let err as HermesDataError {
            #expect(err.description.contains("profiles"))
        }
    }
}
