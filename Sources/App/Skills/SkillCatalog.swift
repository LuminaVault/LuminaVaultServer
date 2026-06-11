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
    private let scanBuiltin: Bool
    private var builtinManifests: [SkillManifest]?
    private var builtinScanAttempted = false

    init(
        vaultPaths: VaultPathService,
        parser: SkillManifestParser = SkillManifestParser(),
        scanBuiltin: Bool = true,
        logger: Logger
    ) {
        self.vaultPaths = vaultPaths
        self.parser = parser
        self.scanBuiltin = scanBuiltin
        self.logger = logger
    }

    /// Returns the merged manifest list for `tenantID`. Vault entries
    /// shadow built-in entries with the same `name` (HER-168 acceptance).
    ///
    /// HER-247: minimal implementation scans the bundled
    /// `Resources/Skills/<name>/SKILL.md` (built-in) plus, per tenant,
    /// `<vaultRoot>/tenants/<id>/skills/<name>/SKILL.md` (vault). Vault skills
    /// override built-ins of the same name. Vault scanning (HER-168) backs
    /// chat-created **Jobs** (Jobs P3) — a job is a vault skill with a cron
    /// schedule, picked up by `CronScheduler` like any other skill.
    func manifests(for tenantID: UUID) async throws -> [SkillManifest] {
        var byName: [String: SkillManifest] = [:]
        // Built-ins first (so vault can override by name). Cached per process
        // because CronScheduler re-queries on every tick.
        if scanBuiltin {
            if !builtinScanAttempted {
                builtinScanAttempted = true
                if let resourceRoot = Bundle.module.resourceURL?.appendingPathComponent("Skills", isDirectory: true) {
                    builtinManifests = scan(directory: resourceRoot, source: .builtin)
                } else {
                    builtinManifests = []
                }
            }
            for manifest in builtinManifests ?? [] {
                byName[manifest.name] = manifest
            }
        }
        // Vault skills override.
        let vaultSkills = vaultPaths.tenantRoot(for: tenantID).appendingPathComponent("skills", isDirectory: true)
        for manifest in scan(directory: vaultSkills, source: .vault) {
            byName[manifest.name] = manifest
        }
        return byName.values.sorted { $0.name < $1.name }
    }

    /// Scans a `<dir>/<name>/SKILL.md` layout, parsing each manifest with the
    /// given source. Missing dir / parse failures are skipped (logged).
    private func scan(directory: URL, source: SkillManifest.Source) -> [SkillManifest] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else {
            return []
        }
        var manifests: [SkillManifest] = []
        for dir in dirs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let skillFile = dir.appendingPathComponent("SKILL.md")
            guard fm.fileExists(atPath: skillFile.path) else { continue }
            do {
                let contents = try String(contentsOf: skillFile, encoding: .utf8)
                try manifests.append(parser.parse(source: source, contents: contents))
            } catch {
                logger.warning("skill_catalog parse failure", metadata: [
                    "skill": .string(dir.lastPathComponent),
                    "source": .string(source.rawValue),
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
