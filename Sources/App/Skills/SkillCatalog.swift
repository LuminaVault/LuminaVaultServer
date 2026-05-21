import Foundation
import Logging

/// Loads `SkillManifest`s for a tenant from two sources:
/// - **builtin**: shipped in the App target's resource bundle at
///   `Resources/Skills/<name>/SKILL.md` (`Bundle.module.resourceURL`).
/// - **vault**: scanned from `<vaultRoot>/skills/<name>/SKILL.md` for the
///   requesting tenant. Vault skills override built-ins of the same name.
///
/// DB (`skills_state`, M19) tracks runtime state only — `enabled` flag,
/// `last_run_at`, etc. The manifest itself is never stored in Postgres;
/// the filesystem is the source of truth.
///
/// HER-148 scaffold: actor surface + stubbed loaders returning empty.
/// Real implementation in HER-168.
actor SkillCatalog {
    private let vaultPaths: VaultPathService
    private let parser: SkillManifestParser
    private let logger: Logger

    init(
        vaultPaths: VaultPathService,
        parser: SkillManifestParser = SkillManifestParser(),
        logger: Logger,
    ) {
        self.vaultPaths = vaultPaths
        self.parser = parser
        self.logger = logger
    }

    /// Returns the merged manifest list for `tenantID`. Vault entries
    /// shadow built-in entries with the same `name` (HER-168 acceptance).
    ///
    /// HER-247: minimal implementation scans the bundled
    /// `Resources/Skills/<name>/SKILL.md` files. Vault scanning is
    /// deferred to HER-168.
    func manifests(for _: UUID) async throws -> [SkillManifest] {
        guard let resourceRoot = Bundle.module.resourceURL?
            .appendingPathComponent("Skills", isDirectory: true)
        else {
            return []
        }
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(
            at: resourceRoot,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else {
            return []
        }
        var manifests: [SkillManifest] = []
        manifests.reserveCapacity(dirs.count)
        for dir in dirs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let skillFile = dir.appendingPathComponent("SKILL.md")
            guard fm.fileExists(atPath: skillFile.path) else { continue }
            do {
                let contents = try String(contentsOf: skillFile, encoding: .utf8)
                let manifest = try parser.parse(source: .builtin, contents: contents)
                manifests.append(manifest)
            } catch {
                logger.warning("skill_catalog parse failure", metadata: [
                    "skill": .string(dir.lastPathComponent),
                    "error": .string(String(describing: error)),
                ])
                continue
            }
        }
        return manifests
    }

    /// Convenience lookup for the route handler / runner. Returns `nil` if
    /// no skill with that `name` is loaded for the tenant.
    func manifest(named name: String, for tenantID: UUID) async throws -> SkillManifest? {
        try await manifests(for: tenantID).first(where: { $0.name == name })
    }
}
