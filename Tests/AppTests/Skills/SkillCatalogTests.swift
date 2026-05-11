@testable import App
import Foundation
import Logging
import Testing

/// HER-168 — `SkillCatalog` behavior. The real `SkillManifestParser` is a
/// HER-167 stub that throws, so these tests inject a synthetic parser
/// that extracts the `name:` line from the frontmatter and synthesizes a
/// minimal `SkillManifest`. That isolates the catalog's discovery /
/// dedup / tenant / reload behavior from parser correctness, which is
/// covered separately by `SkillManifestTests`.
@Suite(.serialized)
struct SkillCatalogTests {
    /// Synthetic parser: pulls the `name:` line out of frontmatter and
    /// builds a manifest with otherwise-empty fields. Throws if the line
    /// is missing — exercises the catalog's "skip + log" path.
    private static let stubParser = SkillManifestParser(parseOverride: { source, contents in
        let nameLine = contents
            .split(separator: "\n")
            .lazy
            .compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("name:") else { return nil }
                return String(trimmed.dropFirst("name:".count).trimmingCharacters(in: .whitespaces))
            }
            .first
        guard let name = nameLine, !name.isEmpty else {
            throw SkillManifestError.missingRequiredField("name")
        }
        return SkillManifest(
            source: source,
            name: name,
            description: "stub-\(name)",
            allowedTools: [],
            capability: .low,
            schedule: nil,
            onEvent: [],
            outputs: [],
            dailyRunCap: nil,
            body: "",
        )
    })

    /// One-shot scratch directory. Deleted at the end of each test by
    /// `withTemp`.
    private static func withTemp<T>(_ body: (URL) throws -> T) throws -> T {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lv-skillcat-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        return try body(dir)
    }

    private static func writeSkill(at root: URL, name: String, body extra: String = "") throws {
        let skillDir = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
        let contents = """
        ---
        name: \(name)
        \(extra)
        ---
        body for \(name)
        """
        try contents.write(to: skillDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    }

    private static func makeCatalog(
        vaultRoot: URL,
        builtinRoot: URL?,
    ) -> SkillCatalog {
        SkillCatalog(
            vaultPaths: VaultPathService(rootPath: vaultRoot.path),
            parser: Self.stubParser,
            builtinRootOverride: builtinRoot,
            logger: Logger(label: "test.skill-catalog"),
        )
    }

    @Test
    func `empty builtin + empty vault yields no manifests`() async throws {
        try await Self.withTempAsync { tmp in
            let builtin = tmp.appendingPathComponent("builtin-empty")
            let vaultRoot = tmp.appendingPathComponent("vault")
            try FileManager.default.createDirectory(at: builtin, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: vaultRoot, withIntermediateDirectories: true)
            let catalog = Self.makeCatalog(vaultRoot: vaultRoot, builtinRoot: builtin)
            let result = try await catalog.manifests(for: UUID())
            #expect(result.isEmpty)
        }
    }

    @Test
    func `builtin manifests are discovered`() async throws {
        try await Self.withTempAsync { tmp in
            let builtin = tmp.appendingPathComponent("builtin")
            let vaultRoot = tmp.appendingPathComponent("vault")
            try FileManager.default.createDirectory(at: builtin, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: vaultRoot, withIntermediateDirectories: true)
            try Self.writeSkill(at: builtin, name: "daily-brief")
            try Self.writeSkill(at: builtin, name: "weekly-memo")

            let catalog = Self.makeCatalog(vaultRoot: vaultRoot, builtinRoot: builtin)
            let result = try await catalog.manifests(for: UUID())
            #expect(result.map(\.name) == ["daily-brief", "weekly-memo"])
            #expect(result.allSatisfy { $0.source == .builtin })
        }
    }

    @Test
    func `vault overrides builtin of the same name`() async throws {
        try await Self.withTempAsync { tmp in
            let builtin = tmp.appendingPathComponent("builtin")
            let vaultRoot = tmp.appendingPathComponent("vault")
            try FileManager.default.createDirectory(at: builtin, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: vaultRoot, withIntermediateDirectories: true)
            try Self.writeSkill(at: builtin, name: "daily-brief")
            try Self.writeSkill(at: builtin, name: "weekly-memo")

            let tenantID = UUID()
            let tenantSkills = vaultRoot
                .appendingPathComponent("tenants")
                .appendingPathComponent(tenantID.uuidString)
                .appendingPathComponent("skills")
            try FileManager.default.createDirectory(at: tenantSkills, withIntermediateDirectories: true)
            try Self.writeSkill(at: tenantSkills, name: "daily-brief")

            let catalog = Self.makeCatalog(vaultRoot: vaultRoot, builtinRoot: builtin)
            let result = try await catalog.manifests(for: tenantID)
            let dailyBrief = try #require(result.first(where: { $0.name == "daily-brief" }))
            #expect(dailyBrief.source == .vault, "vault must win on name conflict")
            #expect(result.map(\.name).sorted() == ["daily-brief", "weekly-memo"])
            #expect(result.first(where: { $0.name == "weekly-memo" })?.source == .builtin)
        }
    }

    @Test
    func `tenants do not see each other vault skills`() async throws {
        try await Self.withTempAsync { tmp in
            let builtin = tmp.appendingPathComponent("builtin-empty")
            let vaultRoot = tmp.appendingPathComponent("vault")
            try FileManager.default.createDirectory(at: builtin, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: vaultRoot, withIntermediateDirectories: true)
            let t1 = UUID()
            let t2 = UUID()
            let t1Skills = vaultRoot.appendingPathComponent("tenants").appendingPathComponent(t1.uuidString).appendingPathComponent("skills")
            let t2Skills = vaultRoot.appendingPathComponent("tenants").appendingPathComponent(t2.uuidString).appendingPathComponent("skills")
            try FileManager.default.createDirectory(at: t1Skills, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: t2Skills, withIntermediateDirectories: true)
            try Self.writeSkill(at: t1Skills, name: "t1-private")
            try Self.writeSkill(at: t2Skills, name: "t2-private")

            let catalog = Self.makeCatalog(vaultRoot: vaultRoot, builtinRoot: builtin)
            let t1Result = try await catalog.manifests(for: t1)
            let t2Result = try await catalog.manifests(for: t2)
            #expect(t1Result.map(\.name) == ["t1-private"])
            #expect(t2Result.map(\.name) == ["t2-private"])
        }
    }

    @Test
    func `catalog reload picks up new skills without restart`() async throws {
        try await Self.withTempAsync { tmp in
            let builtin = tmp.appendingPathComponent("builtin-empty")
            let vaultRoot = tmp.appendingPathComponent("vault")
            try FileManager.default.createDirectory(at: builtin, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: vaultRoot, withIntermediateDirectories: true)
            let tenantID = UUID()
            let tenantSkills = vaultRoot
                .appendingPathComponent("tenants")
                .appendingPathComponent(tenantID.uuidString)
                .appendingPathComponent("skills")
            try FileManager.default.createDirectory(at: tenantSkills, withIntermediateDirectories: true)

            let catalog = Self.makeCatalog(vaultRoot: vaultRoot, builtinRoot: builtin)
            let initial = try await catalog.manifests(for: tenantID)
            #expect(initial.isEmpty)

            try Self.writeSkill(at: tenantSkills, name: "hot-loaded")
            let afterAdd = try await catalog.manifests(for: tenantID)
            #expect(afterAdd.map(\.name) == ["hot-loaded"])

            try FileManager.default.removeItem(at: tenantSkills.appendingPathComponent("hot-loaded"))
            let afterRemove = try await catalog.manifests(for: tenantID)
            #expect(afterRemove.isEmpty)
        }
    }

    @Test
    func `name slash dir mismatch is rejected`() async throws {
        try await Self.withTempAsync { tmp in
            let builtin = tmp.appendingPathComponent("builtin")
            let vaultRoot = tmp.appendingPathComponent("vault")
            try FileManager.default.createDirectory(at: builtin, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: vaultRoot, withIntermediateDirectories: true)
            // Directory is `attacker` but manifest claims `daily-brief`.
            // Without the dir-name check, a vault skill could shadow any
            // builtin by lying about its `name`.
            try Self.writeSkill(at: builtin, name: "attacker")
            let dir = builtin.appendingPathComponent("attacker")
            let payload = "---\nname: daily-brief\n---\nattacker body"
            try payload.write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

            let catalog = Self.makeCatalog(vaultRoot: vaultRoot, builtinRoot: builtin)
            let result = try await catalog.manifests(for: UUID())
            #expect(result.isEmpty, "mismatched name/dir manifest must be dropped")
        }
    }

    @Test
    func `parse failures are logged and skipped not raised`() async throws {
        try await Self.withTempAsync { tmp in
            let builtin = tmp.appendingPathComponent("builtin")
            let vaultRoot = tmp.appendingPathComponent("vault")
            try FileManager.default.createDirectory(at: builtin, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: vaultRoot, withIntermediateDirectories: true)
            // Good skill alongside one with no `name:` line.
            try Self.writeSkill(at: builtin, name: "good")
            let badDir = builtin.appendingPathComponent("bad", isDirectory: true)
            try FileManager.default.createDirectory(at: badDir, withIntermediateDirectories: true)
            try "no frontmatter at all".write(
                to: badDir.appendingPathComponent("SKILL.md"),
                atomically: true,
                encoding: .utf8,
            )

            let catalog = Self.makeCatalog(vaultRoot: vaultRoot, builtinRoot: builtin)
            let result = try await catalog.manifests(for: UUID())
            #expect(result.map(\.name) == ["good"], "parser failure must skip the entry, not abort the scan")
        }
    }

    private static func withTempAsync<T>(_ body: @Sendable (URL) async throws -> T) async throws -> T {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lv-skillcat-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            let result = try await body(dir)
            try? FileManager.default.removeItem(at: dir)
            return result
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
    }
}
