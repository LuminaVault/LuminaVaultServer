import Foundation
import Logging

/// Loads `SkillManifest`s for a tenant from two sources:
/// - **builtin**: shipped in the App target's resource bundle at
///   `Resources/Skills/<name>/SKILL.md` (`Bundle.module.resourceURL`).
/// - **vault**: scanned from `<vaultRoot>/tenants/<tenantID>/skills/<name>/SKILL.md`.
///   Vault skills override built-ins of the same name.
///
/// DB (`skills_state`, M19) tracks runtime state only — `enabled` flag,
/// `last_run_at`, etc. The manifest itself is never stored in Postgres;
/// the filesystem is the source of truth.
///
/// HER-168: per-call scan (no in-memory cache). This satisfies the
/// "catalog reload survives skill add/remove without server restart"
/// acceptance criterion at the cost of one directory walk per request.
/// At expected catalog size (≤20 entries per tenant) this is cheaper
/// than the bookkeeping a cache invalidation layer would add. Revisit
/// with a watcher + cache if the scan ever shows up in a flamegraph.
actor SkillCatalog {
    private let vaultPaths: VaultPathService
    private let parser: SkillManifestParser
    private let bundle: Bundle
    private let builtinRootOverride: URL?
    private let fileManager: FileManager
    private let logger: Logger

    init(
        vaultPaths: VaultPathService,
        parser: SkillManifestParser = SkillManifestParser(),
        bundle: Bundle = .module,
        builtinRootOverride: URL? = nil,
        fileManager: FileManager = .default,
        logger: Logger,
    ) {
        self.vaultPaths = vaultPaths
        self.parser = parser
        self.bundle = bundle
        self.builtinRootOverride = builtinRootOverride
        self.fileManager = fileManager
        self.logger = logger
    }

    /// Returns the merged manifest list for `tenantID`. Vault entries
    /// shadow built-in entries with the same `name` (HER-168 acceptance).
    ///
    /// Invalid manifests (missing or malformed frontmatter, schema
    /// violations) are logged and skipped — they never partially load
    /// and never abort the rest of the catalog. Same source-of-truth
    /// principle as the `SkillManifestParser` invariants.
    func manifests(for tenantID: UUID) async throws -> [SkillManifest] {
        let builtins = loadDirectory(builtinSkillsRoot(), source: .builtin)
        let vault = loadDirectory(vaultPaths.skillsDirectory(for: tenantID), source: .vault)

        // Vault precedence: walk built-ins first, then overlay vault.
        // The dictionary key is the manifest `name`; later writes win.
        var merged: [String: SkillManifest] = [:]
        for manifest in builtins {
            merged[manifest.name] = manifest
        }
        for manifest in vault {
            merged[manifest.name] = manifest
        }
        return merged.values.sorted(by: { $0.name < $1.name })
    }

    /// Convenience lookup for the route handler / runner. Returns `nil` if
    /// no skill with that `name` is loaded for the tenant.
    func manifest(named name: String, for tenantID: UUID) async throws -> SkillManifest? {
        try await manifests(for: tenantID).first(where: { $0.name == name })
    }

    // MARK: - Filesystem

    /// Resolves the bundle's `Resources/Skills/` directory. The Swift
    /// Package Manager copies `Resources/Skills` verbatim via `.copy` in
    /// `Package.swift`, so the on-disk layout is preserved inside
    /// `Bundle.module.resourceURL`.
    private func builtinSkillsRoot() -> URL? {
        if let builtinRootOverride { return builtinRootOverride }
        return bundle.resourceURL?.appendingPathComponent("Skills", isDirectory: true)
    }

    /// Walks `<root>/<name>/SKILL.md`, parses each into a `SkillManifest`,
    /// returns the successful ones. Missing root → empty. Read or parse
    /// failures are logged at warning and dropped.
    private func loadDirectory(_ root: URL?, source: SkillManifest.Source) -> [SkillManifest] {
        guard let root else { return [] }
        guard fileManager.fileExists(atPath: root.path) else { return [] }
        let entries: [URL]
        do {
            entries = try fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
            )
        } catch {
            logger.warning("skills.catalog directory scan failed root=\(root.path) source=\(source.rawValue): \(error)")
            return []
        }
        var manifests: [SkillManifest] = []
        for entry in entries {
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDirectory else { continue }
            let skillFile = entry.appendingPathComponent("SKILL.md")
            guard fileManager.fileExists(atPath: skillFile.path) else { continue }
            do {
                let contents = try String(contentsOf: skillFile, encoding: .utf8)
                let manifest = try parser.parse(source: source, contents: contents)
                // Guard against a manifest whose `name` doesn't match its
                // containing directory. The catalog keys on `name`, so a
                // mismatch would let a vault skill silently override a
                // builtin it shouldn't. Reject those at scan time.
                let dirName = entry.lastPathComponent
                guard manifest.name == dirName else {
                    logger.warning("skills.catalog name/dir mismatch source=\(source.rawValue) dir=\(dirName) manifestName=\(manifest.name) — skipping")
                    continue
                }
                manifests.append(manifest)
            } catch {
                logger.warning("skills.catalog parse failed source=\(source.rawValue) path=\(skillFile.path): \(error)")
            }
        }
        return manifests
    }
}
