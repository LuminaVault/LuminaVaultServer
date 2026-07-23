import Crypto
import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import Logging
import LuminaVaultShared
import SQLKit

actor SelfImprovementService {
    private let fluent: HummingbirdFluent.Fluent
    private let catalog: SkillCatalog
    private let vaultPaths: VaultPathService
    private let soulService: SOULService
    private let llm: any HermesLLMService
    private let capabilities: HermesRemoteCapabilitiesService?
    private let economyModel: String
    private let mainModel: String
    private let globallyEnabled: Bool
    private let logger: Logger
    private let parser = SkillManifestParser()

    init(
        fluent: HummingbirdFluent.Fluent,
        catalog: SkillCatalog,
        vaultPaths: VaultPathService,
        soulService: SOULService,
        llm: any HermesLLMService,
        capabilities: HermesRemoteCapabilitiesService?,
        economyModel: String,
        mainModel: String,
        globallyEnabled: Bool,
        logger: Logger
    ) {
        self.fluent = fluent
        self.catalog = catalog
        self.vaultPaths = vaultPaths
        self.soulService = soulService
        self.llm = llm
        self.capabilities = capabilities
        self.economyModel = economyModel
        self.mainModel = mainModel
        self.globallyEnabled = globallyEnabled
        self.logger = logger
    }

    // MARK: - Public API

    func status(for user: User) async throws -> ImprovementStatusDTO {
        let tenantID = try user.requireID()
        let settings = try await settings(for: tenantID)
        let pending = try await ImprovementChange.query(on: fluent.db())
            .filter(\.$tenantID == tenantID)
            .filter(\.$state == ImprovementChangeState.pending.rawValue)
            .count()
        let availability: ImprovementAvailability
        let message: String?
        if !globallyEnabled {
            availability = .unavailable
            message = "Self-improvement is temporarily disabled by the operator."
        } else if let capabilities, await capabilities.isUserOverride(tenantID: tenantID) {
            availability = .readOnly
            message = "Self-improvement is read-only when using a bring-your-own Hermes endpoint."
        } else {
            availability = .managed
            message = nil
        }
        return ImprovementStatusDTO(
            settings: settings.toDTO(),
            availability: availability,
            economyModelAvailable: !economyModel.isEmpty,
            pendingChanges: pending,
            lastCuratorReviewAt: settings.lastCuratorReviewAt,
            lastSoulReviewAt: settings.lastSoulReviewAt,
            nextReviewAt: settings.nextReviewAt,
            message: message
        )
    }

    func updateSettings(_ dto: ImprovementSettingsDTO, for user: User) async throws -> ImprovementStatusDTO {
        try Self.validate(dto)
        let tenantID = try user.requireID()
        try await requireManaged(tenantID: tenantID)
        let row = try await settings(for: tenantID)
        row.apply(dto)
        // Saving the cadence is also an explicit reschedule. Otherwise a
        // changed interval would retain its old due date until the next run.
        row.nextReviewAt = Date().addingTimeInterval(TimeInterval(dto.intervalHours * 3600))
        try await row.save(on: fluent.db())
        return try await status(for: user)
    }

    func enqueueCurator(for user: User, trigger: ImprovementTrigger, dryRun: Bool) async throws -> ImprovementRunDTO {
        let tenantID = try user.requireID()
        if !dryRun {
            let settings = try await settings(for: tenantID)
            guard settings.enabled, settings.curatorEnabled else {
                throw HTTPError(.conflict, message: "curator_disabled")
            }
        }
        return try await enqueue(tenantID: tenantID, kind: .curator, trigger: trigger, dryRun: dryRun)
    }

    func enqueueSoulReview(for user: User, trigger: ImprovementTrigger) async throws -> ImprovementRunDTO {
        let tenantID = try user.requireID()
        let settings = try await settings(for: tenantID)
        guard settings.enabled, settings.soulReviewEnabled else {
            throw HTTPError(.conflict, message: "soul_review_disabled")
        }
        if let capabilities, await capabilities.isUserOverride(tenantID: tenantID) {
            throw HTTPError(.conflict, message: "soul_review_unsupported_on_byo_hermes")
        }
        return try await enqueue(tenantID: tenantID, kind: .soul, trigger: trigger, dryRun: false)
    }

    func runs(for user: User, limit: Int = 50) async throws -> ImprovementRunsResponse {
        let tenantID = try user.requireID()
        let rows = try await ImprovementRun.query(on: fluent.db())
            .filter(\.$tenantID == tenantID)
            .sort(\.$createdAt, .descending)
            .limit(min(max(limit, 1), 100))
            .all()
        return try ImprovementRunsResponse(runs: rows.map { try $0.toDTO() })
    }

    func run(id: UUID, for user: User) async throws -> ImprovementRunDTO {
        let tenantID = try user.requireID()
        guard let row = try await ImprovementRun.query(on: fluent.db())
            .filter(\.$id == id)
            .filter(\.$tenantID == tenantID)
            .first()
        else { throw HTTPError(.notFound, message: "self_improvement_run_not_found") }
        return try row.toDTO()
    }

    func changes(for user: User) async throws -> ImprovementChangesResponse {
        let tenantID = try user.requireID()
        let rows = try await ImprovementChange.query(on: fluent.db())
            .filter(\.$tenantID == tenantID)
            .sort(\.$createdAt, .descending)
            .limit(100)
            .all()
        return try ImprovementChangesResponse(changes: rows.map { try $0.toDTO() })
    }

    func resources(for user: User) async throws -> ImprovementSkillsResponse {
        let tenantID = try user.requireID()
        let manifests = try await catalog.manifests(for: tenantID).filter { $0.source == .vault }
        let states = try await SkillsState.query(on: fluent.db())
            .filter(\.$id == tenantID)
            .filter(\.$source == SkillManifest.Source.vault.rawValue)
            .all()
        let stateByName = Dictionary(uniqueKeysWithValues: states.map { ($0.name, $0) })
        var items = manifests.map { manifest in
            let state = stateByName[manifest.name]
            return ImprovementSkillDTO(
                name: manifest.name,
                title: manifest.description,
                kind: Self.resourceKind(manifest),
                state: ImprovementResourceState(rawValue: state?.curatorState ?? "active") ?? .active,
                pinned: state?.curatorPinned ?? false,
                curatorManaged: true,
                lastActivityAt: state?.curatorLastActivityAt
            )
        }
        let visibleNames = Set(manifests.map(\.name))
        items.append(contentsOf: states.compactMap { state in
            guard !visibleNames.contains(state.name), state.curatorState == ImprovementResourceState.archived.rawValue else {
                return nil
            }
            return ImprovementSkillDTO(
                name: state.name,
                title: state.name,
                kind: state.name.hasPrefix("job-") ? .job : .skill,
                state: .archived,
                pinned: state.curatorPinned,
                curatorManaged: true,
                lastActivityAt: state.curatorLastActivityAt
            )
        })
        return ImprovementSkillsResponse(skills: items.sorted { $0.name < $1.name })
    }

    func setPinned(_ pinned: Bool, kind: ImprovementResourceKind, name: String, for user: User) async throws -> ImprovementSkillDTO {
        guard Self.validResourceName(name) else { throw HTTPError(.badRequest, message: "invalid_resource_name") }
        let tenantID = try user.requireID()
        try await requireManaged(tenantID: tenantID)
        let manifest = try await catalog.manifest(named: name, for: tenantID)
        let existing = try await SkillsState.query(on: fluent.db())
            .filter(\.$id == tenantID)
            .filter(\.$source == SkillManifest.Source.vault.rawValue)
            .filter(\.$name == name)
            .first()
        guard manifest?.source == .vault || existing?.curatorState == ImprovementResourceState.archived.rawValue else {
            throw HTTPError(.notFound, message: "curator_resource_not_found")
        }
        if let manifest, Self.resourceKind(manifest) != kind {
            throw HTTPError(.conflict, message: "resource_kind_mismatch")
        }
        let state = existing ?? SkillsState(tenantID: tenantID, source: "vault", name: name)
        state.curatorPinned = pinned
        try await state.save(on: fluent.db())
        return ImprovementSkillDTO(
            name: name,
            title: manifest?.description ?? name,
            kind: kind,
            state: ImprovementResourceState(rawValue: state.curatorState) ?? .active,
            pinned: pinned,
            curatorManaged: true,
            lastActivityAt: state.curatorLastActivityAt
        )
    }

    func decide(changeID: UUID, approve: Bool, for user: User) async throws -> ImprovementChangeDTO {
        let tenantID = try user.requireID()
        try await requireManaged(tenantID: tenantID)
        guard let change = try await ImprovementChange.query(on: fluent.db())
            .filter(\.$id == changeID)
            .filter(\.$tenantID == tenantID)
            .first()
        else { throw HTTPError(.notFound, message: "self_improvement_change_not_found") }
        guard change.state == ImprovementChangeState.pending.rawValue else {
            throw HTTPError(.conflict, message: "self_improvement_change_already_decided")
        }
        change.decidedAt = Date()
        guard approve else {
            change.state = ImprovementChangeState.rejected.rawValue
            try await change.save(on: fluent.db())
            return try change.toDTO()
        }
        if let capabilities, await capabilities.isUserOverride(tenantID: tenantID) {
            throw HTTPError(.conflict, message: "soul_unsupported_on_byo_hermes")
        }
        let current = try soulService.read(for: user)
        guard Self.sha256(current) == change.baseSHA256 else {
            change.state = ImprovementChangeState.stale.rawValue
            try await change.save(on: fluent.db())
            throw HTTPError(.conflict, message: "soul_changed_since_review")
        }
        guard let proposed = change.proposedMarkdown else {
            change.state = ImprovementChangeState.failed.rawValue
            change.failureReason = "proposal payload missing"
            try await change.save(on: fluent.db())
            throw HTTPError(.conflict, message: "soul_proposal_missing")
        }
        _ = try soulService.write(for: user, body: proposed)
        change.state = ImprovementChangeState.applied.rawValue
        change.appliedAt = Date()
        try await change.save(on: fluent.db())
        return try change.toDTO()
    }

    func rollback(runID: UUID, for user: User) async throws -> ImprovementRunDTO {
        let tenantID = try user.requireID()
        try await requireManaged(tenantID: tenantID)
        guard let run = try await ImprovementRun.query(on: fluent.db())
            .filter(\.$id == runID)
            .filter(\.$tenantID == tenantID)
            .first(),
            let raw = run.snapshotJSON,
            let data = raw.data(using: .utf8),
            let snapshots = try? JSONDecoder().decode([ResourceSnapshot].self, from: data),
            !snapshots.isEmpty
        else { throw HTTPError(.conflict, message: "rollback_snapshot_unavailable") }
        for snapshot in snapshots {
            let active = skillFile(tenantID: tenantID, name: snapshot.name)
            if FileManager.default.fileExists(atPath: active.path),
               let current = try? String(contentsOf: active, encoding: .utf8),
               let afterSHA = snapshot.afterSHA,
               Self.sha256(current) != afterSHA
            {
                throw HTTPError(.conflict, message: "resource_changed_since_curator_run")
            }
        }
        for snapshot in snapshots {
            let active = skillFile(tenantID: tenantID, name: snapshot.name)
            try FileManager.default.createDirectory(at: active.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(snapshot.markdown.utf8).write(to: active, options: .atomic)
            if let archivedPath = snapshot.archivedPath {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: archivedPath))
            }
            if let state = try await state(tenantID: tenantID, name: snapshot.name, create: true) {
                state.curatorState = snapshot.state
                state.curatorArchivedAt = nil
                try await state.save(on: fluent.db())
            }
        }
        run.status = ImprovementRunStatus.rolledBack.rawValue
        try await run.save(on: fluent.db())
        return try run.toDTO()
    }

    func noteActivity(tenantID: UUID, at date: Date = Date()) async {
        guard let row = try? await settings(for: tenantID) else { return }
        row.lastActivityAt = date
        try? await row.save(on: fluent.db())
    }

    func triggerComplexSession(tenantID: UUID, toolCallCount: Int, createdWorkflow: Bool = false) async {
        guard toolCallCount >= 5 || createdWorkflow else { return }
        do {
            let row = try await settings(for: tenantID)
            guard globallyEnabled, row.enabled, row.soulReviewEnabled, row.reviewComplexSessions else { return }
            if let last = row.lastSoulReviewAt,
               Date().timeIntervalSince(last) < TimeInterval(row.soulReviewCooldownHours * 3600)
            {
                return
            }
            _ = try await enqueue(tenantID: tenantID, kind: .soul, trigger: .complexSession, dryRun: false)
        } catch {
            logger.warning("self_improvement.complex_trigger_failed tenant=\(tenantID) error=\(error)")
        }
    }

    // MARK: - Scheduler

    func tick(now: Date = Date()) async {
        do {
            try await enqueueDueReviews(now: now)
            guard let run = try await claimQueuedRun(now: now) else { return }
            try await process(run)
        } catch {
            logger.error("self_improvement.tick_failed error=\(error)")
        }
    }

    // MARK: - Queue

    private func enqueue(
        tenantID: UUID,
        kind: ImprovementChangeKind,
        trigger: ImprovementTrigger,
        dryRun: Bool
    ) async throws -> ImprovementRunDTO {
        try await requireManaged(tenantID: tenantID)
        let active = try await ImprovementRun.query(on: fluent.db())
            .filter(\.$tenantID == tenantID)
            .filter(\.$kind == kind.rawValue)
            .group(.or) { group in
                group.filter(\.$status == ImprovementRunStatus.queued.rawValue)
                group.filter(\.$status == ImprovementRunStatus.running.rawValue)
            }
            .sort(\.$createdAt, .descending)
            .first()
        if let active, active.dryRun == dryRun {
            return try active.toDTO()
        }
        if active != nil {
            throw HTTPError(.conflict, message: "self_improvement_run_already_active")
        }
        let run = ImprovementRun(tenantID: tenantID, kind: kind, trigger: trigger, dryRun: dryRun)
        try await run.save(on: fluent.db())
        return try run.toDTO()
    }

    private func enqueueDueReviews(now: Date) async throws {
        guard globallyEnabled, let sql = fluent.db() as? any SQLDatabase else { return }
        // The migration seeds existing tenants. This keeps the default-on
        // contract true for accounts created after that migration as well,
        // even if they never open the settings screen.
        try await sql.raw("""
        INSERT INTO self_improvement_settings (id, tenant_id, next_review_at)
        SELECT gen_random_uuid(), id, \(bind: now.addingTimeInterval(168 * 3600)) FROM users
        ON CONFLICT (tenant_id) DO NOTHING
        """).run()
        struct DueRow: Decodable { let tenant_id: UUID; let curator_enabled: Bool; let soul_review_enabled: Bool }
        let rows = try await sql.raw("""
        UPDATE self_improvement_settings
        SET lease_until = \(bind: now.addingTimeInterval(600)),
            next_review_at = \(bind: now) + (interval_hours || ' hours')::interval,
            updated_at = \(bind: now)
        WHERE id IN (
          SELECT id FROM self_improvement_settings
          WHERE enabled = TRUE
            AND next_review_at <= \(bind: now)
            AND (lease_until IS NULL OR lease_until < \(bind: now))
            AND (last_activity_at IS NULL OR last_activity_at <= \(bind: now) - (minimum_idle_hours || ' hours')::interval)
          ORDER BY next_review_at ASC
          FOR UPDATE SKIP LOCKED
          LIMIT 10
        )
        RETURNING tenant_id, curator_enabled, soul_review_enabled
        """).all(decoding: DueRow.self)
        for row in rows {
            if row.curator_enabled {
                _ = try await enqueue(tenantID: row.tenant_id, kind: .curator, trigger: .weekly, dryRun: false)
            }
            if row.soul_review_enabled {
                _ = try await enqueue(tenantID: row.tenant_id, kind: .soul, trigger: .weekly, dryRun: false)
            }
        }
    }

    private func claimQueuedRun(now: Date) async throws -> ImprovementRun? {
        guard let sql = fluent.db() as? any SQLDatabase else { return nil }
        struct Claimed: Decodable { let id: UUID }
        guard let row = try await sql.raw("""
        UPDATE self_improvement_runs
        SET status = 'running', started_at = \(bind: now)
        WHERE id = (
          SELECT id FROM self_improvement_runs
          WHERE status = 'queued'
          ORDER BY created_at ASC
          FOR UPDATE SKIP LOCKED
          LIMIT 1
        )
        RETURNING id
        """).first(decoding: Claimed.self) else { return nil }
        return try await ImprovementRun.find(row.id, on: fluent.db())
    }

    private func process(_ run: ImprovementRun) async throws {
        do {
            switch ImprovementChangeKind(rawValue: run.kind) ?? .curator {
            case .curator:
                try await processCurator(run)
            case .soul:
                try await processSoulReview(run)
            }
            run.status = ImprovementRunStatus.succeeded.rawValue
        } catch {
            run.status = ImprovementRunStatus.failed.rawValue
            run.failureReason = String(describing: error)
            logger.warning("self_improvement.run_failed id=\((try? run.requireID())?.uuidString ?? "?") error=\(error)")
        }
        run.endedAt = Date()
        try await run.save(on: fluent.db())
    }

    // MARK: - Curator

    private func processCurator(_ run: ImprovementRun) async throws {
        let tenantID = run.tenantID
        try await requireManaged(tenantID: tenantID)
        let settings = try await settings(for: tenantID)
        guard run.dryRun || (globallyEnabled && settings.enabled && settings.curatorEnabled) else {
            throw HTTPError(.serviceUnavailable, message: "curator_disabled")
        }
        let manifests = try await catalog.manifests(for: tenantID).filter { $0.source == .vault }
        var report: [String] = try [
            "# Curator Report",
            "",
            "- Run: \((run.requireID()).uuidString)",
            "- Mode: \(run.dryRun ? "dry-run" : "live")",
            "- Candidates: \(manifests.count)",
            "",
        ]
        var snapshots: [ResourceSnapshot] = []
        var applied = 0
        var skipped = 0
        let now = Date()

        for manifest in manifests {
            let state = try await state(tenantID: tenantID, name: manifest.name, create: true)
            guard let state else { continue }
            let lastActivity = try await lastActivity(tenantID: tenantID, manifest: manifest)
            state.curatorLastActivityAt = lastActivity
            if state.curatorPinned {
                skipped += 1
                report.append("- Skipped `\(manifest.name)` — pinned.")
                if !run.dryRun {
                    try await state.save(on: fluent.db())
                }
                continue
            }
            let idleDays = now.timeIntervalSince(lastActivity) / 86400
            if idleDays >= 90 {
                report.append("- \(run.dryRun ? "Would archive" : "Archived") `\(manifest.name)` after \(Int(idleDays)) idle days.")
                if !run.dryRun {
                    try snapshots.append(snapshot(tenantID: tenantID, manifest: manifest, state: state))
                    let archivedPath = try archive(tenantID: tenantID, name: manifest.name, runID: run.requireID())
                    snapshots[snapshots.count - 1].archivedPath = archivedPath.path
                    state.curatorState = ImprovementResourceState.archived.rawValue
                    state.curatorArchivedAt = now
                    try await state.save(on: fluent.db())
                    applied += 1
                }
            } else if idleDays >= 30, state.curatorState == ImprovementResourceState.active.rawValue {
                report.append("- \(run.dryRun ? "Would mark" : "Marked") `\(manifest.name)` stale after \(Int(idleDays)) idle days.")
                if !run.dryRun {
                    try snapshots.append(snapshot(tenantID: tenantID, manifest: manifest, state: state))
                    state.curatorState = ImprovementResourceState.stale.rawValue
                    try await state.save(on: fluent.db())
                    applied += 1
                }
            } else if !run.dryRun {
                try await state.save(on: fluent.db())
            }
        }

        let consolidationCandidates = try await catalog.manifests(for: tenantID).filter {
            $0.source == .vault && Self.resourceKind($0) == .skill
        }
        var unpinned: [SkillManifest] = []
        for manifest in consolidationCandidates {
            let state = try await state(tenantID: tenantID, name: manifest.name, create: true)
            if state?.curatorPinned != true,
               state?.curatorState != ImprovementResourceState.archived.rawValue
            {
                unpinned.append(manifest)
            }
        }
        if settings.consolidate, unpinned.count >= 2 {
            let result = try await consolidate(
                tenantID: tenantID,
                candidates: Array(unpinned.prefix(40)),
                settings: settings,
                dryRun: run.dryRun,
                runID: run.requireID(),
                snapshots: &snapshots
            )
            run.modelUsed = result.model
            applied += result.applied
            skipped += result.skipped
            report.append(contentsOf: result.report)
        } else {
            report.append("- Consolidation skipped — fewer than two eligible skills or disabled.")
        }

        run.actionsApplied = applied
        run.actionsSkipped = skipped
        run.reportMarkdown = report.joined(separator: "\n")
        if !run.dryRun, !snapshots.isEmpty {
            run.snapshotJSON = try String(data: JSONEncoder().encode(snapshots), encoding: .utf8)
            try await pruneSnapshots(tenantID: tenantID, keep: settings.backupKeep)
        }
        if !run.dryRun {
            settings.lastCuratorReviewAt = now
            settings.leaseUntil = nil
            try await settings.save(on: fluent.db())
            try writeReportBestEffort(run.reportMarkdown ?? "", tenantID: tenantID, runID: run.requireID())
        }
    }

    private struct ConsolidationResult { let model: String; let applied: Int; let skipped: Int; let report: [String] }

    private func consolidate(
        tenantID: UUID,
        candidates: [SkillManifest],
        settings: ImprovementSettings,
        dryRun: Bool,
        runID: UUID,
        snapshots: inout [ResourceSnapshot]
    ) async throws -> ConsolidationResult {
        let documents = candidates.compactMap { manifest -> String? in
            let url = skillFile(tenantID: tenantID, name: manifest.name)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return "<skill name=\"\(manifest.name)\">\n\(String(text.prefix(16000)))\n</skill>"
        }.joined(separator: "\n\n")
        let model = settings.modelMode == ImprovementModelMode.economy.rawValue ? economyModel : mainModel
        guard !model.isEmpty else { throw HTTPError(.serviceUnavailable, message: "economy_model_unavailable") }
        let prompt = """
        Review these LuminaVault skills conservatively. Find only clear duplication or drift.
        Return JSON only: {"actions":[{"action":"keep|patch|merge","name":"skill","target":"optional-target","reason":"short","replacement_markdown":"full SKILL.md or null"}]}.
        Never change schedules, add tools, edit jobs, or invent capabilities. Prefer keep. A merge replaces target and archives name.

        \(String(documents.prefix(60000)))
        """
        let response = try await llm.chat(
            sessionKey: tenantID.uuidString,
            sessionID: nil,
            request: ChatRequest(messages: [ChatMessage(role: "user", content: prompt)], model: model, temperature: 0.1)
        )
        let envelope = try Self.decodeJSON(ConsolidationEnvelope.self, from: response.message.content)
        let byName = Dictionary(uniqueKeysWithValues: candidates.map { ($0.name, $0) })
        var report = ["", "## Consolidation", ""]
        var applied = 0
        var skipped = 0
        for action in envelope.actions.prefix(20) {
            guard ["keep", "patch", "merge"].contains(action.action) else {
                skipped += 1
                report.append("- Rejected unknown action for `\(action.name)`.")
                continue
            }
            guard action.action != "keep" else {
                report.append("- Kept `\(action.name)`: \(action.reason)")
                continue
            }
            guard let original = byName[action.name], let replacement = action.replacementMarkdown else {
                skipped += 1; report.append("- Skipped invalid action for `\(action.name)`."); continue
            }
            let targetName = action.action == "merge" ? action.target : action.name
            guard let targetName, let target = byName[targetName], target.schedule == nil,
                  let parsed = try? parser.parse(source: .vault, contents: replacement),
                  parsed.name == targetName,
                  parsed.schedule == target.schedule,
                  Set(parsed.allowedTools).isSubset(of: Set(original.allowedTools + target.allowedTools))
            else {
                skipped += 1; report.append("- Rejected unsafe `\(action.action)` for `\(action.name)`."); continue
            }
            report.append("- \(dryRun ? "Would \(action.action)" : action.action.capitalized) `\(action.name)`\(targetName == action.name ? "" : " into `\(targetName)`"): \(action.reason)")
            guard !dryRun else { continue }
            guard let targetState = try await state(tenantID: tenantID, name: targetName, create: true), !targetState.curatorPinned else {
                skipped += 1; continue
            }
            try snapshots.append(snapshot(tenantID: tenantID, manifest: target, state: targetState))
            try Data(replacement.utf8).write(to: skillFile(tenantID: tenantID, name: targetName), options: .atomic)
            snapshots[snapshots.count - 1].afterSHA = Self.sha256(replacement)
            if action.action == "merge", action.name != targetName,
               let sourceState = try await state(tenantID: tenantID, name: action.name, create: true), !sourceState.curatorPinned
            {
                try snapshots.append(snapshot(tenantID: tenantID, manifest: original, state: sourceState))
                let archived = try archive(tenantID: tenantID, name: action.name, runID: runID)
                snapshots[snapshots.count - 1].archivedPath = archived.path
                sourceState.curatorState = ImprovementResourceState.archived.rawValue
                sourceState.curatorArchivedAt = Date()
                try await sourceState.save(on: fluent.db())
            }
            applied += 1
        }
        return ConsolidationResult(model: response.model, applied: applied, skipped: skipped, report: report)
    }

    // MARK: - SOUL reviewer

    private func processSoulReview(_ run: ImprovementRun) async throws {
        let tenantID = run.tenantID
        let settings = try await settings(for: tenantID)
        guard globallyEnabled, settings.enabled, settings.soulReviewEnabled else {
            throw HTTPError(.serviceUnavailable, message: "soul_review_disabled")
        }
        guard let user = try await User.find(tenantID, on: fluent.db()) else {
            throw HTTPError(.notFound, message: "user_not_found")
        }
        if let capabilities, await capabilities.isUserOverride(tenantID: tenantID) {
            throw HTTPError(.conflict, message: "soul_review_unsupported_on_byo_hermes")
        }
        let soul = try soulService.read(for: user)
        let history = try await recentConversationText(tenantID: tenantID, days: settings.soulReviewWindowDays)
        let model = settings.modelMode == ImprovementModelMode.economy.rawValue ? economyModel : mainModel
        guard !model.isEmpty else { throw HTTPError(.serviceUnavailable, message: "economy_model_unavailable") }
        let prompt = """
        Review the last \(settings.soulReviewWindowDays) days of sessions and the current SOUL.md. Identify drift in mission, voice, priorities, or constraints. Propose a precise, minimal patch only if needed. Be conservative. Never remove or weaken locked safety constraints.
        Return JSON only: {"needed":true|false,"summary":"short reason","proposed_markdown":"complete SOUL.md or null"}.

        <current_soul>\n\(soul)\n</current_soul>
        <recent_sessions>\n\(String(history.prefix(60000)))\n</recent_sessions>
        """
        let response = try await llm.chat(
            sessionKey: tenantID.uuidString,
            sessionID: nil,
            request: ChatRequest(messages: [ChatMessage(role: "user", content: prompt)], model: model, temperature: 0.1)
        )
        let review = try Self.decodeJSON(SoulReviewEnvelope.self, from: response.message.content)
        run.modelUsed = response.model
        var report = ["# SOUL Review", "", review.summary]
        if review.needed, let proposed = review.proposedMarkdown {
            let enforced = SOULCore.inject(into: proposed)
            guard enforced.lengthOfBytes(using: .utf8) <= SOULService.maxSizeBytes,
                  Self.isConservativeChange(from: soul, to: enforced)
            else { throw HTTPError(.unprocessableContent, message: "soul_review_patch_too_broad") }
            let change = ImprovementChange()
            change.tenantID = tenantID
            change.runID = try run.requireID()
            change.kind = ImprovementChangeKind.soul.rawValue
            change.state = ImprovementChangeState.pending.rawValue
            change.trigger = run.trigger
            change.title = "SOUL.md review"
            change.summary = review.summary
            change.patch = Self.simpleDiff(from: soul, to: enforced)
            change.proposedMarkdown = enforced
            change.baseSHA256 = Self.sha256(soul)
            change.reportMarkdown = report.joined(separator: "\n")
            try await change.save(on: fluent.db())
            report.append("\nA conservative patch is waiting for approval.")
        } else {
            report.append("\nNo SOUL.md change is needed.")
        }
        run.reportMarkdown = report.joined(separator: "\n")
        settings.lastSoulReviewAt = Date()
        settings.leaseUntil = nil
        try await settings.save(on: fluent.db())
        try writeReportBestEffort(run.reportMarkdown ?? "", tenantID: tenantID, runID: run.requireID())
    }

    // MARK: - Helpers

    private func requireManaged(tenantID: UUID) async throws {
        guard globallyEnabled else {
            throw HTTPError(.serviceUnavailable, message: "self_improvement_disabled")
        }
        if let capabilities, await capabilities.isUserOverride(tenantID: tenantID) {
            throw HTTPError(.conflict, message: "self_improvement_read_only_on_byo_hermes")
        }
    }

    private func settings(for tenantID: UUID) async throws -> ImprovementSettings {
        if let existing = try await ImprovementSettings.query(on: fluent.db())
            .filter(\.$tenantID == tenantID)
            .first()
        {
            return existing
        }
        let created = ImprovementSettings(tenantID: tenantID)
        try await created.save(on: fluent.db())
        return created
    }

    private func state(tenantID: UUID, name: String, create: Bool) async throws -> SkillsState? {
        if let row = try await SkillsState.query(on: fluent.db())
            .filter(\.$id == tenantID)
            .filter(\.$source == SkillManifest.Source.vault.rawValue)
            .filter(\.$name == name)
            .first()
        {
            return row
        }
        return create ? SkillsState(tenantID: tenantID, source: "vault", name: name) : nil
    }

    private func lastActivity(tenantID: UUID, manifest: SkillManifest) async throws -> Date {
        if let sql = fluent.db() as? any SQLDatabase {
            struct Row: Decodable { let last_run_at: Date? }
            let row = try await sql.raw("SELECT MAX(started_at) AS last_run_at FROM skill_run_log WHERE tenant_id = \(bind: tenantID) AND name = \(bind: manifest.name)").first(decoding: Row.self)
            if let last = row?.last_run_at {
                return last
            }
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: skillFile(tenantID: tenantID, name: manifest.name).path)
        return attributes?[.modificationDate] as? Date ?? Date()
    }

    private func recentConversationText(tenantID: UUID, days: Int) async throws -> String {
        guard let sql = fluent.db() as? any SQLDatabase else { return "" }
        struct Row: Decodable { let role: String; let content: String; let created_at: Date }
        let since = Date().addingTimeInterval(TimeInterval(-days * 86400))
        let rows = try await sql.raw("""
        SELECT m.role, m.content, m.created_at
        FROM conversation_messages m
        JOIN conversations c ON c.id = m.conversation_id
        WHERE c.tenant_id = \(bind: tenantID) AND m.created_at >= \(bind: since)
        ORDER BY m.created_at ASC
        LIMIT 500
        """).all(decoding: Row.self)
        return rows.map { "[\($0.created_at.ISO8601Format())] \($0.role): \($0.content)" }.joined(separator: "\n")
    }

    private func snapshot(tenantID: UUID, manifest: SkillManifest, state: SkillsState) throws -> ResourceSnapshot {
        let markdown = try String(contentsOf: skillFile(tenantID: tenantID, name: manifest.name), encoding: .utf8)
        return ResourceSnapshot(name: manifest.name, markdown: markdown, state: state.curatorState, afterSHA: nil, archivedPath: nil)
    }

    private func archive(tenantID: UUID, name: String, runID: UUID) throws -> URL {
        let source = skillFile(tenantID: tenantID, name: name).deletingLastPathComponent()
        let target = vaultPaths.tenantRoot(for: tenantID)
            .appendingPathComponent("skills/.archive", isDirectory: true)
            .appendingPathComponent("\(name)-\(runID.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: source, to: target)
        return target
    }

    private func skillFile(tenantID: UUID, name: String) -> URL {
        vaultPaths.tenantRoot(for: tenantID)
            .appendingPathComponent("skills", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
            .appendingPathComponent("SKILL.md")
    }

    private func writeReport(_ markdown: String, tenantID: UUID, runID: UUID) throws {
        let directory = vaultPaths.tenantRoot(for: tenantID)
            .appendingPathComponent("reports/self-improvement", isDirectory: true)
            .appendingPathComponent(runID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(markdown.utf8).write(to: directory.appendingPathComponent("REPORT.md"), options: .atomic)
    }

    private func writeReportBestEffort(_ markdown: String, tenantID: UUID, runID: UUID) {
        do {
            try writeReport(markdown, tenantID: tenantID, runID: runID)
        } catch {
            // The database copy remains authoritative; a failed convenience
            // mirror must not turn already-applied curator work into a failed
            // run with misleading rollback semantics.
            logger.warning("self_improvement.report_mirror_failed run=\(runID) error=\(error)")
        }
    }

    private func pruneSnapshots(tenantID: UUID, keep: Int) async throws {
        let rows = try await ImprovementRun.query(on: fluent.db())
            .filter(\.$tenantID == tenantID)
            .filter(\.$dryRun == false)
            .filter(\.$kind == ImprovementChangeKind.curator.rawValue)
            .sort(\.$createdAt, .descending)
            .all()
        let backedUpRuns = rows.filter { $0.snapshotJSON != nil }
        for row in backedUpRuns.dropFirst(max(1, keep)) {
            row.snapshotJSON = nil
            try await row.save(on: fluent.db())
        }
    }

    private static func validate(_ dto: ImprovementSettingsDTO) throws {
        guard (24 ... 720).contains(dto.intervalHours),
              (0 ... 72).contains(dto.minimumIdleHours),
              (1 ... 20).contains(dto.backupKeep),
              (7 ... 14).contains(dto.soulReviewWindowDays),
              (1 ... 168).contains(dto.soulReviewCooldownHours),
              !dto.pruneBuiltins
        else { throw HTTPError(.badRequest, message: "invalid_self_improvement_settings") }
    }

    private static func resourceKind(_ manifest: SkillManifest) -> ImprovementResourceKind {
        manifest.name.hasPrefix("job-") || manifest.schedule != nil ? .job : .skill
    }

    /// Internal for unit tests (`@testable`).
    static func validResourceName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 80 && name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    /// Internal for unit tests (`@testable`).
    static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Internal for unit tests (`@testable`).
    static func decodeJSON<T: Decodable>(_ type: T.Type, from raw: String) throws -> T {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let unfenced: String
        if trimmed.hasPrefix("```") {
            let lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false)
            unfenced = lines.dropFirst().dropLast().joined(separator: "\n")
        } else {
            unfenced = trimmed
        }
        guard let data = unfenced.data(using: .utf8) else { throw HTTPError(.badGateway, message: "review_output_invalid") }
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw HTTPError(.badGateway, message: "review_output_invalid_json") }
    }

    /// Line-set symmetric-difference gate for SOUL proposals. Internal for unit tests.
    static func isConservativeChange(from old: String, to new: String) -> Bool {
        let oldLines = Set(old.split(separator: "\n").map(String.init))
        let newLines = Set(new.split(separator: "\n").map(String.init))
        let changed = oldLines.symmetricDifference(newLines).count
        return changed <= max(20, oldLines.count / 3)
    }

    private static func simpleDiff(from old: String, to new: String) -> String {
        let oldLines = old.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let newLines = new.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var lines = ["--- SOUL.md", "+++ SOUL.md (proposed)"]
        lines.append(contentsOf: oldLines.filter { !newLines.contains($0) }.map { "-\($0)" })
        lines.append(contentsOf: newLines.filter { !oldLines.contains($0) }.map { "+\($0)" })
        return lines.joined(separator: "\n")
    }
}

private struct ConsolidationEnvelope: Decodable {
    struct Action: Decodable {
        let action: String
        let name: String
        let target: String?
        let reason: String
        let replacementMarkdown: String?

        enum CodingKeys: String, CodingKey {
            case action, name, target, reason
            case replacementMarkdown = "replacement_markdown"
        }
    }

    let actions: [Action]
}

private struct SoulReviewEnvelope: Decodable {
    let needed: Bool
    let summary: String
    let proposedMarkdown: String?

    enum CodingKeys: String, CodingKey {
        case needed, summary
        case proposedMarkdown = "proposed_markdown"
    }
}

private struct ResourceSnapshot: Codable, Sendable {
    let name: String
    let markdown: String
    let state: String
    var afterSHA: String?
    var archivedPath: String?
}
