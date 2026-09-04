import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import Logging
import LuminaVaultShared

/// Runs a memory compile over freshly imported vault files. Production wraps
/// `MemoryCompileController`; tests record the request.
protocol HermesMirrorCompileRunning: Sendable {
    func compile(tenantID: UUID, vaultFileIDs: [UUID]) async throws
}

struct MemoryCompileControllerRunner: HermesMirrorCompileRunning {
    let controller: MemoryCompileController
    let fluent: Fluent

    func compile(tenantID: UUID, vaultFileIDs: [UUID]) async throws {
        guard let user = try await User.find(tenantID, on: fluent.db()) else {
            throw HTTPError(.notFound, message: "user_not_found")
        }
        _ = try await controller.compile(user: user, body: KBCompileRequest(vaultFileIds: vaultFileIDs))
    }
}

/// Resumable position of a capped vault import: the last absolute path the
/// deterministic (sorted, depth-first) walk finished with.
struct HermesVaultImportCursor: Codable, Sendable, Equatable {
    let vaultPath: String
    let lastPath: String
    let scanned: Int
}

/// Resumable position of a sessions import. `offset` walks the
/// newest-first listing; `highWater` is the `lastActive` of the newest
/// session fully imported by a previous complete pass, so later passes stop
/// as soon as they reach already-imported history.
struct HermesSessionsImportCursor: Codable, Sendable, Equatable {
    var offset: Int
    var highWater: Double?
    var runHighWater: Double?
}

/// Hermes Mirror — the product moat: every skill, cron job, KB vault file
/// and past session on the user's Hermes, mirrored into LuminaVault.
///
/// One actor for all tenants; every operation is tenant-scoped and the
/// per-tenant `inFlight` set stops two imports racing the same cursor.
/// Network and file IO happen in the transports; the actor only touches
/// Postgres and the in-memory guards, so reentrancy across `await`s is safe
/// (state rows are re-read after each transport call).
actor HermesMirrorService {
    struct Limits: Sendable {
        var maxVaultFiles = 5000
        var maxFileBytes = HermesDashboardClient.fileBodyCap
        var ingestBatchSize = 50
        /// Files processed per `importVault` call; the refresh worker
        /// continues from the cursor until the walk completes.
        var vaultFilesPerRun = 200
        /// ≤ 20 requests/s against a user's dashboard.
        var readPause: Duration = .milliseconds(50)
        var maxSessions = 2000
        var maxSessionBytes = 1024 * 1024
        var sessionsPerRun = 100
        var sessionPageSize = 50
    }

    static let compileJobName = "luminavault-nightly-compile"
    static let compileJobSchedule = "0 3 * * *"
    static let vaultSpaceName = "Hermes Vault"
    static let sessionsSpaceName = "Hermes Sessions"
    static let vaultProvenance = "hermes-mirror"
    static let sessionProvenance = "hermes-session"
    static let skippedDirectories: Set<String> = [".obsidian", ".trash", ".kb", ".git", "node_modules"]

    let fluent: Fluent
    let transports: any HermesMirrorTransportProviding
    let capabilities: HermesRemoteCapabilitiesService?
    let ingest: VaultIngestService
    let compile: (any HermesMirrorCompileRunning)?
    let bundledSkills: HermesBundledSkills
    let limits: Limits
    let logger: Logger
    let clock: @Sendable () -> Date
    private var inFlight: Set<UUID> = []

    init(
        fluent: Fluent,
        transports: any HermesMirrorTransportProviding,
        capabilities: HermesRemoteCapabilitiesService?,
        ingest: VaultIngestService,
        compile: (any HermesMirrorCompileRunning)?,
        bundledSkills: HermesBundledSkills = HermesBundledSkills(),
        limits: Limits = Limits(),
        logger: Logger,
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.fluent = fluent
        self.transports = transports
        self.capabilities = capabilities
        self.ingest = ingest
        self.compile = compile
        self.bundledSkills = bundledSkills
        self.limits = limits
        self.logger = logger
        self.clock = clock
    }

    // MARK: - Status

    func status(tenantID: UUID) async throws -> HermesMirrorStatusDTO {
        let state = try await loadState(tenantID: tenantID)
        let kind = await transports.kind(tenantID: tenantID)
        let dashboard = await capabilities?.capabilities(tenantID: tenantID).capabilities.dashboard
        return Self.statusDTO(state: state, kind: kind, dashboard: dashboard)
    }

    static func statusDTO(state: HermesMirrorState?, kind: HermesMirrorTransportKind, dashboard: HermesDashboardCapabilitiesDTO?) -> HermesMirrorStatusDTO {
        HermesMirrorStatusDTO(
            transport: kind,
            lastSyncAt: state?.lastSyncAt,
            lastStatus: state.flatMap { HermesMirrorSyncStatus(rawValue: $0.lastStatus) } ?? .never,
            lastError: state?.lastError,
            skillsCount: state?.skillsCount ?? 0,
            jobsCount: state?.jobsCount ?? 0,
            vaultFilesCount: state?.vaultFilesCount ?? 0,
            vaultPath: state?.vaultPath,
            vaultState: state.flatMap { HermesMirrorVaultState(rawValue: $0.vaultState) } ?? .absent,
            sessionsImported: state?.sessionsImported ?? 0,
            compileJobID: state?.compileJobID,
            dashboard: dashboard
        )
    }

    // MARK: - Sync (skills, jobs, vault detection)

    /// Runs each scope independently, records partial failures, and returns
    /// the refreshed status. Never throws for an upstream failure — the
    /// status carries `lastStatus`/`lastError` instead.
    func sync(tenantID: UUID, scopes: Set<HermesMirrorSyncScope>) async throws -> HermesMirrorStatusDTO {
        let scopes = scopes.isEmpty ? Set(HermesMirrorSyncScope.allCases) : scopes
        let state = try await ensureState(tenantID: tenantID)
        var errors: [String] = []
        var succeeded = 0
        let transport: any HermesMirrorTransport
        do {
            transport = try await transports.transport(tenantID: tenantID)
        } catch {
            try await record(state: state, status: .failed, error: Self.describe(error))
            return try await status(tenantID: tenantID)
        }

        if scopes.contains(.skills) {
            do {
                let skills = try await transport.listSkills()
                try await replaceSkills(tenantID: tenantID, with: skills)
                state.skillsCount = skills.count
                succeeded += 1
            } catch {
                errors.append("skills: \(Self.describe(error))")
            }
        }
        if scopes.contains(.jobs) {
            do {
                let jobs = try await transport.listJobs()
                try await replaceJobs(tenantID: tenantID, with: jobs)
                state.jobsCount = jobs.count
                if let compileJobID = state.compileJobID, !jobs.contains(where: { $0.id == compileJobID }) {
                    state.compileJobID = jobs.first { $0.name == Self.compileJobName }?.id
                }
                succeeded += 1
            } catch {
                errors.append("jobs: \(Self.describe(error))")
            }
        }
        if scopes.contains(.vault) {
            do {
                if let detected = try await detectVault(transport: transport, preferred: state.vaultPath) {
                    state.vaultPath = detected
                    if state.vaultState == HermesMirrorVaultState.absent.rawValue {
                        state.vaultState = HermesMirrorVaultState.detected.rawValue
                    }
                } else if state.vaultState != HermesMirrorVaultState.created.rawValue {
                    state.vaultState = HermesMirrorVaultState.absent.rawValue
                    state.vaultPath = nil
                }
                succeeded += 1
            } catch {
                errors.append("vault: \(Self.describe(error))")
            }
        }

        let status: HermesMirrorSyncStatus = errors.isEmpty ? .ok : (succeeded > 0 ? .partial : .failed)
        try await record(state: state, status: status, error: errors.isEmpty ? nil : errors.joined(separator: "; "))
        return try await self.status(tenantID: tenantID)
    }

    private func replaceSkills(tenantID: UUID, with skills: [HermesMirrorSkill]) async throws {
        let db = fluent.db()
        let existing = try await HermesMirroredSkill.query(on: db, tenantID: tenantID).all()
        var byName = Dictionary(existing.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        for skill in skills {
            if let row = byName.removeValue(forKey: skill.name) {
                let changed = row.description != skill.description || row.enabled != skill.enabled
                    || row.source != skill.source.rawValue || row.contentHash != skill.contentHash
                if changed {
                    row.description = skill.description
                    row.enabled = skill.enabled
                    row.source = skill.source.rawValue
                    row.contentHash = skill.contentHash
                    try await row.save(on: db)
                }
            } else {
                try await HermesMirroredSkill(tenantID: tenantID, skill: skill).save(on: db)
            }
        }
        for stale in byName.values {
            try await stale.delete(on: db)
        }
    }

    private func replaceJobs(tenantID: UUID, with jobs: [HermesMirrorJob]) async throws {
        let db = fluent.db()
        let existing = try await HermesMirroredJob.query(on: db, tenantID: tenantID).all()
        var byID = Dictionary(existing.map { ($0.hermesJobID, $0) }, uniquingKeysWith: { first, _ in first })
        for job in jobs {
            if let row = byID.removeValue(forKey: job.id) {
                row.apply(job)
                try await row.save(on: db)
            } else {
                try await HermesMirroredJob(tenantID: tenantID, job: job).save(on: db)
            }
        }
        for stale in byID.values {
            try await stale.delete(on: db)
        }
    }

    // MARK: - Skills

    func mirroredSkills(tenantID: UUID) async throws -> [HermesMirroredSkillDTO] {
        try await HermesMirroredSkill.query(on: fluent.db(), tenantID: tenantID)
            .sort(\.$name)
            .all()
            .map(Self.skillDTO)
    }

    static func skillDTO(_ row: HermesMirroredSkill) -> HermesMirroredSkillDTO {
        HermesMirroredSkillDTO(
            name: row.name,
            description: row.description,
            enabled: row.enabled,
            source: HermesMirroredSkillSource(rawValue: row.source) ?? .custom,
            updatedAt: row.updatedAt
        )
    }

    /// Toggle on Hermes, then mirror the new flag locally.
    func toggleSkill(tenantID: UUID, name: String, enabled: Bool) async throws -> HermesMirroredSkillDTO {
        let db = fluent.db()
        // Fluent query builder, not a collection.
        // swiftlint:disable:next first_where
        guard let row = try await HermesMirroredSkill.query(on: db, tenantID: tenantID).filter(\.$name == name).first() else {
            throw HTTPError(.notFound, message: "hermes_skill_not_found")
        }
        let transport = try await transports.transport(tenantID: tenantID)
        try await transport.toggleSkill(name: name, enabled: enabled)
        row.enabled = enabled
        try await row.save(on: db)
        return Self.skillDTO(row)
    }

    // MARK: - Jobs

    /// Live from Hermes when reachable; otherwise the last mirrored snapshot
    /// with `source: snapshot` so clients can badge staleness.
    func jobs(tenantID: UUID) async throws -> HermesMirroredJobsResponse {
        do {
            let transport = try await transports.transport(tenantID: tenantID)
            let live = try await transport.listJobs()
            try await replaceJobs(tenantID: tenantID, with: live)
            return HermesMirroredJobsResponse(source: .live, jobs: live.map(Self.jobDTO))
        } catch {
            logger.debug("hermes mirror live jobs failed; serving snapshot", metadata: ["tenant": .string(tenantID.uuidString), "error": "\(Self.describe(error))"])
            let rows = try await HermesMirroredJob.query(on: fluent.db(), tenantID: tenantID).sort(\.$hermesJobID).all()
            return HermesMirroredJobsResponse(source: .snapshot, jobs: rows.map(Self.jobDTO))
        }
    }

    static func jobDTO(_ job: HermesMirrorJob) -> HermesMirroredJobDTO {
        HermesMirroredJobDTO(
            hermesJobID: job.id,
            name: job.name,
            schedule: job.schedule,
            prompt: job.prompt,
            paused: job.paused,
            lastRunAt: job.lastRunAt,
            nextRunAt: job.nextRunAt,
            updatedAt: nil
        )
    }

    static func jobDTO(_ row: HermesMirroredJob) -> HermesMirroredJobDTO {
        HermesMirroredJobDTO(
            hermesJobID: row.hermesJobID,
            name: row.name,
            schedule: row.schedule,
            prompt: row.prompt,
            paused: row.paused,
            lastRunAt: row.lastRunAt,
            nextRunAt: row.nextRunAt,
            updatedAt: row.updatedAt
        )
    }

    // MARK: - Vault detection

    /// Finds the KB root on the user's Hermes: a directory holding
    /// `.kb/manifest.json`, or both `raw/` and `wiki/`, looked up under the
    /// dashboard's working directory (and one level below `obsidian-vault/`),
    /// else a `kb-config.json` pointer, else the previously known path.
    func detectVault(transport: any HermesMirrorTransport, preferred: String?) async throws -> String? {
        if let preferred, await Self.isVaultRoot(transport, preferred) {
            return preferred
        }
        let status = try await transport.status()
        guard let cwd = status.defaultCwd, let base = try? HermesMirrorPath.validate(cwd) else { return nil }
        var candidates = [base, HermesMirrorPath.join(base, "kb"), HermesMirrorPath.join(base, "vault"), HermesMirrorPath.join(base, "obsidian-vault")]
        if let pointer = await Self.readKBConfigPointer(transport, base) {
            candidates.insert(pointer, at: 0)
        }
        for candidate in candidates {
            guard await Self.isVaultRoot(transport, candidate) else { continue }
            return candidate
        }
        let vaults = HermesMirrorPath.join(base, "obsidian-vault")
        if let entries = try? await transport.listFiles(path: vaults) {
            for entry in entries where entry.isDirectory && !entry.name.hasPrefix(".") {
                guard await Self.isVaultRoot(transport, entry.path) else { continue }
                return entry.path
            }
        }
        return nil
    }

    private static func isVaultRoot(_ transport: any HermesMirrorTransport, _ path: String) async -> Bool {
        guard let entries = try? await transport.listFiles(path: path) else { return false }
        let names = Set(entries.filter(\.isDirectory).map(\.name))
        if names.contains(".kb"), let kb = try? await transport.listFiles(path: HermesMirrorPath.join(path, ".kb")),
           kb.contains(where: { $0.name == "manifest.json" && !$0.isDirectory })
        {
            return true
        }
        return names.contains("raw") && names.contains("wiki")
    }

    private static func readKBConfigPointer(_ transport: any HermesMirrorTransport, _ base: String) async -> String? {
        guard let text = try? await transport.readText(path: HermesMirrorPath.join(base, "kb-config.json")),
              let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        else { return nil }
        let raw = (object["kb_path"] as? String) ?? (object["root"] as? String) ?? (object["path"] as? String)
        guard let raw else { return nil }
        let absolute = raw.hasPrefix("/") ? raw : HermesMirrorPath.join(base, raw)
        return try? HermesMirrorPath.validate(absolute)
    }

    // MARK: - Vault import

    func importVault(tenantID: UUID, requestedPath: String?) async throws -> HermesVaultImportResultDTO {
        try beginExclusive(tenantID)
        defer { endExclusive(tenantID) }
        let state = try await ensureState(tenantID: tenantID)
        let transport = try await transports.transport(tenantID: tenantID)

        let vaultPath: String
        if let requestedPath {
            vaultPath = try HermesMirrorPath.validate(requestedPath)
            let listable = await (try? transport.listFiles(path: vaultPath)) != nil
            guard listable else {
                throw HTTPError(.badRequest, message: "hermes_vault_path_not_found")
            }
        } else if let detected = try await detectVault(transport: transport, preferred: state.vaultPath) {
            vaultPath = detected
        } else {
            throw HTTPError(.notFound, message: "hermes_vault_not_found")
        }

        var cursor = Self.decode(HermesVaultImportCursor.self, state.vaultCursor)
        if cursor?.vaultPath != vaultPath {
            cursor = nil
        }
        var scanned = cursor?.scanned ?? 0
        var resumeFrom = cursor?.lastPath
        var imported = 0
        var skipped = 0
        var failed = 0
        var processedThisRun = 0
        var batch: [VaultIngestService.FileInput] = []
        var lastPath: String?
        var truncated = false

        var stack: [String] = [vaultPath]
        walk: while let directory = stack.popLast() {
            let entries: [HermesMirrorFileEntry]
            do {
                entries = try await transport.listFiles(path: directory)
            } catch {
                failed += 1
                continue
            }
            var subdirectories: [String] = []
            for entry in entries {
                if entry.isDirectory {
                    if !Self.skippedDirectories.contains(entry.name), !entry.name.hasPrefix(".") {
                        subdirectories.append(entry.path)
                    }
                    continue
                }
                guard entry.name.lowercased().hasSuffix(".md") else { continue }
                if let resume = resumeFrom {
                    if entry.path == resume {
                        resumeFrom = nil
                    }
                    continue
                }
                if scanned >= limits.maxVaultFiles {
                    truncated = true
                    break walk
                }
                if processedThisRun >= limits.vaultFilesPerRun {
                    truncated = true
                    break walk
                }
                scanned += 1
                processedThisRun += 1
                lastPath = entry.path
                do {
                    let content = try await transport.readText(path: entry.path)
                    if content.utf8.count > limits.maxFileBytes {
                        skipped += 1
                    } else {
                        let relative = String(entry.path.dropFirst(vaultPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                        batch.append(VaultIngestService.FileInput(path: relative, content: content))
                    }
                } catch let error as HermesMirrorTransportError {
                    switch error {
                    case .bodyTooLarge, .invalidResponse: skipped += 1
                    default: failed += 1
                    }
                }
                if batch.count >= limits.ingestBatchSize {
                    let result = try await ingestVaultBatch(tenantID: tenantID, batch: batch)
                    imported += result.imported
                    skipped += result.skipped
                    failed += result.failed
                    batch.removeAll(keepingCapacity: true)
                }
                try await Task.sleep(for: limits.readPause)
            }
            // Depth-first in sorted order: push reversed so the first child pops first.
            stack.append(contentsOf: subdirectories.sorted().reversed())
        }
        if !batch.isEmpty {
            let result = try await ingestVaultBatch(tenantID: tenantID, batch: batch)
            imported += result.imported
            skipped += result.skipped
            failed += result.failed
        }

        // A stale resume point (file removed on Hermes) means the whole walk
        // was skipped; restart from the top next time.
        if resumeFrom != nil, processedThisRun == 0 {
            state.vaultCursor = nil
            try await state.save(on: fluent.db())
            return HermesVaultImportResultDTO(vaultPath: vaultPath, scanned: scanned, imported: 0, skipped: 0, failed: 0, truncated: true, cursor: nil)
        }

        let vaultFilesCount = try await VaultFile.query(on: fluent.db(), tenantID: tenantID)
            .filter(\.$path, .custom("LIKE"), "\(ImportService.slugify(Self.vaultSpaceName))/%")
            .count()
        state.vaultPath = vaultPath
        state.vaultFilesCount = vaultFilesCount
        state.vaultState = HermesMirrorVaultState.imported.rawValue
        let encodedCursor: String? = if truncated, let lastPath {
            Self.encode(HermesVaultImportCursor(vaultPath: vaultPath, lastPath: lastPath, scanned: scanned))
        } else {
            nil
        }
        state.vaultCursor = encodedCursor
        try await record(state: state, status: failed == 0 ? .ok : .partial, error: failed == 0 ? nil : "vault import: \(failed) file(s) failed")
        logger.info("hermes mirror vault import", metadata: [
            "tenant": .string(tenantID.uuidString), "imported": "\(imported)", "skipped": "\(skipped)",
            "failed": "\(failed)", "truncated": "\(truncated)",
        ])
        return HermesVaultImportResultDTO(vaultPath: vaultPath, scanned: scanned, imported: imported, skipped: skipped, failed: failed, truncated: truncated, cursor: encodedCursor)
    }

    private func ingestVaultBatch(tenantID: UUID, batch: [VaultIngestService.FileInput]) async throws -> VaultIngestService.Result {
        try await ingest.ingestBatch(tenantID: tenantID, spaceName: Self.vaultSpaceName, files: batch, provenance: Self.vaultProvenance)
    }

    private func ingestSessionBatch(tenantID: UUID, batch: [VaultIngestService.FileInput]) async throws -> [UUID] {
        try await ingest.ingestBatch(tenantID: tenantID, spaceName: Self.sessionsSpaceName, files: batch, provenance: Self.sessionProvenance).vaultFileIDs
    }

    /// True when a capped import left a cursor behind (the worker resumes it).
    func hasPendingVaultImport(tenantID: UUID) async throws -> Bool {
        try await loadState(tenantID: tenantID)?.vaultCursor != nil
    }

    // MARK: - Vault create

    /// Creates the KB skeleton on the user's Hermes (`raw/`, `wiki/`, `.kb/`,
    /// manifest, README) and installs every bundled `kb-*` skill that is not
    /// already there. Idempotent: an existing vault is reported, not touched.
    func createVault(tenantID: UUID) async throws -> HermesVaultCreateResultDTO {
        try beginExclusive(tenantID)
        defer { endExclusive(tenantID) }
        let state = try await ensureState(tenantID: tenantID)
        let transport = try await transports.transport(tenantID: tenantID)

        if let existing = try await detectVault(transport: transport, preferred: state.vaultPath) {
            state.vaultPath = existing
            if state.vaultState == HermesMirrorVaultState.absent.rawValue {
                state.vaultState = HermesMirrorVaultState.detected.rawValue
            }
            let installed = try await installMissingKBSkills(transport: transport)
            try await state.save(on: fluent.db())
            return HermesVaultCreateResultDTO(vaultPath: existing, alreadyExisted: true, createdDirectories: [], installedSkills: installed)
        }

        let status = try await transport.status()
        guard let cwd = status.defaultCwd else {
            throw HTTPError(.badGateway, message: "hermes_vault_root_unknown")
        }
        let root = try HermesMirrorPath.join(HermesMirrorPath.validate(cwd), "kb")
        var created: [String] = []
        for directory in [root, HermesMirrorPath.join(root, "raw"), HermesMirrorPath.join(root, "wiki"), HermesMirrorPath.join(root, ".kb")] {
            try await transport.mkdir(path: directory)
            created.append(directory)
        }
        try await transport.writeText(path: HermesMirrorPath.join(root, ".kb/manifest.json"), content: Self.manifestJSON(now: clock()))
        try await transport.writeText(path: HermesMirrorPath.join(root, "README.md"), content: Self.readme(root: root))
        let installed = try await installMissingKBSkills(transport: transport)

        state.vaultPath = root
        state.vaultState = HermesMirrorVaultState.created.rawValue
        try await record(state: state, status: .ok, error: nil)
        return HermesVaultCreateResultDTO(vaultPath: root, alreadyExisted: false, createdDirectories: created, installedSkills: installed)
    }

    private func installMissingKBSkills(transport: any HermesMirrorTransport) async throws -> [String] {
        let present = await Set((try? transport.listSkills())?.map(\.name) ?? [])
        var installed: [String] = []
        for skill in try await bundledSkills.kbSkills() where !present.contains(skill.name) {
            try await transport.createSkill(name: skill.name, content: skill.content)
            installed.append(skill.name)
        }
        return installed
    }

    static func manifestJSON(now: Date) -> String {
        let manifest: [String: JSONValue] = [
            "version": .number(1),
            "created_by": .string("luminavault"),
            "created_at": .string(HermesDates.iso(now)),
            "sources": .array([]),
            "articles": .array([]),
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = (try? encoder.encode(manifest)) ?? Data("{}".utf8)
        return (String(data: data, encoding: .utf8) ?? "{}") + "\n"
    }

    static func readme(root: String) -> String {
        """
        # LuminaVault knowledge base

        Created by LuminaVault at `\(root)`.

        - `raw/` — sources you ingest (`/kb-ingest`, `/kb-import`).
        - `wiki/` — compiled concept articles with backlinks (`/kb-compile`).
        - `.kb/manifest.json` — compile bookkeeping.

        LuminaVault mirrors this vault and runs the nightly `\(HermesMirrorService.compileJobName)` job.

        """
    }

    // MARK: - Sessions import

    func importSessions(tenantID: UUID) async throws -> HermesSessionsImportResultDTO {
        try beginExclusive(tenantID)
        defer { endExclusive(tenantID) }
        let state = try await ensureState(tenantID: tenantID)
        let transport = try await transports.transport(tenantID: tenantID)

        var cursor = Self.decode(HermesSessionsImportCursor.self, state.sessionsCursor) ?? HermesSessionsImportCursor(offset: 0)
        var imported = 0
        var skipped = 0
        var files: [VaultIngestService.FileInput] = []
        var written: [UUID] = []
        var processed = 0
        var reachedHistory = false
        var exhausted = false

        while processed < limits.sessionsPerRun, cursor.offset < limits.maxSessions, !reachedHistory, !exhausted {
            let page = try await transport.listSessions(offset: cursor.offset, limit: limits.sessionPageSize)
            if page.sessions.isEmpty {
                exhausted = true
                break
            }
            for session in page.sessions {
                if processed >= limits.sessionsPerRun || cursor.offset >= limits.maxSessions {
                    break
                }
                cursor.offset += 1
                let lastActive = session.lastActiveAt?.timeIntervalSince1970 ?? session.startedAt?.timeIntervalSince1970
                if let highWater = cursor.highWater, let lastActive, lastActive <= highWater {
                    reachedHistory = true
                    break
                }
                processed += 1
                guard session.messageCount > 0 else {
                    skipped += 1
                    continue
                }
                let messages: [HermesMirrorSessionMessage]
                do {
                    messages = try await transport.sessionMessages(id: session.id)
                } catch {
                    skipped += 1
                    continue
                }
                let markdown = Self.sessionMarkdown(session: session, messages: messages, maxBytes: limits.maxSessionBytes)
                guard let markdown else {
                    skipped += 1
                    continue
                }
                files.append(VaultIngestService.FileInput(path: Self.sessionFileName(session), content: markdown))
                imported += 1
                if let lastActive {
                    cursor.runHighWater = max(cursor.runHighWater ?? 0, lastActive)
                }
                if files.count >= limits.ingestBatchSize {
                    written += try await ingestSessionBatch(tenantID: tenantID, batch: files)
                    files.removeAll(keepingCapacity: true)
                }
                try await Task.sleep(for: limits.readPause)
            }
            if page.sessions.count < limits.sessionPageSize {
                exhausted = true
            }
        }
        if !files.isEmpty {
            written += try await ingestSessionBatch(tenantID: tenantID, batch: files)
        }

        let complete = reachedHistory || exhausted || cursor.offset >= limits.maxSessions
        if complete {
            cursor.highWater = max(cursor.highWater ?? 0, cursor.runHighWater ?? 0)
            cursor.runHighWater = nil
            cursor.offset = 0
        }
        let encodedCursor = complete ? nil : Self.encode(cursor)
        state.sessionsCursor = complete ? Self.encode(cursor) : encodedCursor
        state.sessionsImported += imported

        var compileTriggered = false
        if let compile, !written.isEmpty {
            do {
                try await compile.compile(tenantID: tenantID, vaultFileIDs: written)
                compileTriggered = true
            } catch {
                logger.warning("hermes mirror session compile failed", metadata: ["tenant": .string(tenantID.uuidString), "error": "\(Self.describe(error))"])
            }
        }
        try await record(state: state, status: .ok, error: nil)
        logger.info("hermes mirror sessions import", metadata: [
            "tenant": .string(tenantID.uuidString), "imported": "\(imported)", "skipped": "\(skipped)",
            "files": "\(written.count)", "truncated": "\(!complete)",
        ])
        return HermesSessionsImportResultDTO(
            sessionsImported: imported,
            sessionsSkipped: skipped,
            filesWritten: written.count,
            truncated: !complete,
            cursor: encodedCursor,
            compileTriggered: compileTriggered
        )
    }

    static func sessionFileName(_ session: HermesMirrorSession) -> String {
        let date = session.startedAt ?? session.lastActiveAt ?? Date(timeIntervalSince1970: 0)
        let day = date.formatted(Date.ISO8601FormatStyle().year().month().day())
        let safeID = session.id.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return "sessions/\(day)-\(safeID.isEmpty ? "session" : safeID).md"
    }

    /// Markdown transcript; nil when nothing textual survives. Truncated to
    /// `maxBytes` with a trailing note so a huge session still imports.
    static func sessionMarkdown(session: HermesMirrorSession, messages: [HermesMirrorSessionMessage], maxBytes: Int) -> String? {
        let textual = messages.filter { !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && ($0.role == "user" || $0.role == "assistant") }
        guard !textual.isEmpty else { return nil }
        let trimmedTitle = session.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var lines: [String] = []
        lines.append("# \(trimmedTitle.isEmpty ? "Hermes session \(session.id)" : trimmedTitle)")
        lines.append("")
        lines.append("- session: `\(session.id)`")
        if let source = session.source {
            lines.append("- source: \(source)")
        }
        if let started = session.startedAt {
            lines.append("- started: \(HermesDates.iso(started))")
        }
        if let last = session.lastActiveAt {
            lines.append("- last active: \(HermesDates.iso(last))")
        }
        lines.append("- messages: \(textual.count)")
        lines.append("")
        var body = lines.joined(separator: "\n") + "\n"
        var truncated = false
        for message in textual {
            let heading = message.role == "user" ? "## User" : "## Assistant"
            let stamp = message.timestamp.map { " (\(HermesDates.iso($0)))" } ?? ""
            let block = "\(heading)\(stamp)\n\n\(message.content.trimmingCharacters(in: .whitespacesAndNewlines))\n\n"
            if body.utf8.count + block.utf8.count > maxBytes {
                truncated = true
                break
            }
            body += block
        }
        if truncated {
            body += "_Transcript truncated at \(maxBytes) bytes._\n"
        }
        return body
    }

    // MARK: - Compile cron

    /// Creates (once, by name) the nightly `kb-compile` job on the user's
    /// Hermes and remembers its id.
    func installCompileJob(tenantID: UUID) async throws -> HermesCompileJobInstallResultDTO {
        let state = try await ensureState(tenantID: tenantID)
        let transport = try await transports.transport(tenantID: tenantID)
        let jobs = try await transport.listJobs()
        if let existing = jobs.first(where: { $0.name == Self.compileJobName }) {
            state.compileJobID = existing.id
            try await state.save(on: fluent.db())
            return HermesCompileJobInstallResultDTO(jobID: existing.id, schedule: existing.schedule ?? Self.compileJobSchedule, created: false)
        }
        var vaultPath = state.vaultPath
        if vaultPath == nil {
            vaultPath = try await detectVault(transport: transport, preferred: nil)
        }
        let created = try await transport.createJob(HermesMirrorJobSpec(
            name: Self.compileJobName,
            schedule: Self.compileJobSchedule,
            prompt: Self.compilePrompt(vaultPath: vaultPath),
            deliver: "origin",
            skills: [HermesBundledSkills.compileSkillName]
        ))
        state.compileJobID = created.id
        if let vaultPath {
            state.vaultPath = vaultPath
        }
        try await state.save(on: fluent.db())
        return HermesCompileJobInstallResultDTO(jobID: created.id, schedule: created.schedule ?? Self.compileJobSchedule, created: true)
    }

    static func compilePrompt(vaultPath: String?) -> String {
        let location = vaultPath.map { "The knowledge base lives at `\($0)`." } ?? "Locate the knowledge base (the directory holding `raw/`, `wiki/` and `.kb/manifest.json`)."
        return """
        Run the /kb-compile skill. \(location) Compile every uncompiled file under raw/ into wiki/ concept articles with Obsidian backlinks, update the index, and report how many sources and articles were written. Do not ask questions; skip anything that cannot be compiled and list it at the end.
        """
    }

    // MARK: - State helpers

    func loadState(tenantID: UUID) async throws -> HermesMirrorState? {
        try await HermesMirrorState.query(on: fluent.db(), tenantID: tenantID).first()
    }

    private func ensureState(tenantID: UUID) async throws -> HermesMirrorState {
        if let existing = try await loadState(tenantID: tenantID) {
            return existing
        }
        let created = HermesMirrorState(tenantID: tenantID)
        try await created.save(on: fluent.db())
        return created
    }

    private func record(state: HermesMirrorState, status: HermesMirrorSyncStatus, error: String?) async throws {
        state.lastSyncAt = clock()
        state.lastStatus = status.rawValue
        state.lastError = error.map { String($0.prefix(1000)) }
        try await state.save(on: fluent.db())
    }

    private func beginExclusive(_ tenantID: UUID) throws {
        guard !inFlight.contains(tenantID) else {
            throw HTTPError(.conflict, message: "hermes_mirror_busy")
        }
        inFlight.insert(tenantID)
    }

    private func endExclusive(_ tenantID: UUID) {
        inFlight.remove(tenantID)
    }

    static func describe(_ error: any Error) -> String {
        if let transportError = error as? HermesMirrorTransportError {
            return transportError.description
        }
        if let httpError = error as? HTTPError {
            return httpError.description
        }
        return Logger.redact(String(describing: error))
    }

    static func encode(_ value: some Encodable) -> String? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decode<T: Decodable>(_: T.Type, _ raw: String?) -> T? {
        guard let raw, let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
