@testable import App
import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import Logging
import LuminaVaultShared
import SQLKit
import Testing

/// Hermes Mirror tasks 4–5 — `HermesMirrorService` against the fake
/// transport and a real Postgres: sync with tombstones, live/snapshot jobs,
/// vault detect / import (caps, cursor, path rejection) / create, sessions
/// import with high-water mark + compile trigger, idempotent compile job.
@Suite(.serialized, .tags(.integration), .integrationDatabase, .disabled(if: IntegrationTestEnv.skipIntegration))
struct HermesMirrorServiceTests {
    private static let logger = Logger(label: "test.hermes-mirror")

    private struct FixedTransports: HermesMirrorTransportProviding {
        let transport: FakeHermesMirrorTransport
        func kind(tenantID _: UUID) async -> HermesMirrorTransportKind {
            transport.kind
        }

        func transport(tenantID _: UUID) async throws -> any HermesMirrorTransport {
            transport
        }
    }

    private struct FixedEmbedding: EmbeddingService {
        func embed(_: String, tenantID _: UUID) async throws -> [Float] {
            [Float](repeating: 0.01, count: 1536)
        }
    }

    private actor RecordingCompileRunner: HermesMirrorCompileRunning {
        var calls: [[UUID]] = []
        func compile(tenantID _: UUID, vaultFileIDs: [UUID]) async throws {
            calls.append(vaultFileIDs)
        }

        func recorded() -> [[UUID]] {
            calls
        }
    }

    private struct Harness {
        let fluent: Fluent
        let tenantID: UUID
        let transport: FakeHermesMirrorTransport
        let service: HermesMirrorService
        let compile: RecordingCompileRunner
        let skillsRoot: URL
    }

    private static func slug(_ tag: String) -> String {
        "\(tag)\(UUID().uuidString.prefix(6).lowercased())"
    }

    private func makeHarness(
        fluent: Fluent,
        kind: HermesMirrorTransportKind = .remote,
        limits: HermesMirrorService.Limits = {
            var limits = HermesMirrorService.Limits()
            limits.readPause = .zero
            return limits
        }()
    ) async throws -> Harness {
        await registerMigrations(on: fluent)
        try await fluent.migrate()
        let tenantID = UUID()
        let username = Self.slug("u")
        let user = User(id: tenantID, email: "\(username)@test.luminavault", username: username, passwordHash: "stub")
        try await user.save(on: fluent.db())
        // `spaces.tenant_id` references `vaults.id` (tenant == personal vault).
        try await Vault(id: tenantID, personalOwnerUserID: tenantID, name: "Personal").save(on: fluent.db())

        let vaultRoot = FileManager.default.temporaryDirectory.appendingPathComponent("lv-mirror-vault-\(UUID().uuidString)", isDirectory: true)
        let vaultPaths = VaultPathService(rootPath: vaultRoot.path)
        let ingest = VaultIngestService(
            fluent: fluent,
            vaultPaths: vaultPaths,
            spaces: SpacesService(fluent: fluent, vaultPaths: vaultPaths, logger: Self.logger),
            memories: MemoryRepository(fluent: fluent),
            embeddings: FixedEmbedding(),
            logger: Self.logger
        )
        let skillsRoot = FileManager.default.temporaryDirectory.appendingPathComponent("lv-mirror-skills-\(UUID().uuidString)", isDirectory: true)
        for name in ["kb-compile", "kb-ingest"] {
            let dir = skillsRoot.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("---\nname: \(name)\ndescription: \(name) skill\n---\n".utf8).write(to: dir.appendingPathComponent("SKILL.md"))
        }
        let transport = FakeHermesMirrorTransport(kind: kind)
        let compile = RecordingCompileRunner()
        let service = HermesMirrorService(
            fluent: fluent,
            transports: FixedTransports(transport: transport),
            capabilities: nil,
            ingest: ingest,
            compile: compile,
            bundledSkills: HermesBundledSkills(root: skillsRoot),
            limits: limits,
            logger: Self.logger,
            clock: { Date(timeIntervalSince1970: 1_756_800_000) }
        )
        return Harness(fluent: fluent, tenantID: tenantID, transport: transport, service: service, compile: compile, skillsRoot: skillsRoot)
    }

    private func skill(_ name: String, enabled: Bool = true, description: String = "d") -> HermesMirrorSkill {
        HermesMirrorSkill(name: name, description: description, enabled: enabled, source: .custom, contentHash: nil)
    }

    private func job(_ id: String, name: String, paused: Bool = false) -> HermesMirrorJob {
        HermesMirrorJob(id: id, name: name, schedule: "0 9 * * *", prompt: "p", paused: paused, lastRunAt: nil, nextRunAt: nil, raw: .object(["id": .string(id)]))
    }

    // MARK: - Sync

    @Test
    func `sync mirrors skills and jobs, updates changed rows and tombstones removed ones`() async throws {
        try await withTestFluent(label: "lv.test.mirror.sync") { fluent in
            let h = try await makeHarness(fluent: fluent)
            await h.transport.setSkills([skill("a"), skill("b", enabled: false)])
            await h.transport.setJobs([job("j1", name: "One"), job("j2", name: "Two")])

            var status = try await h.service.sync(tenantID: h.tenantID, scopes: [.skills, .jobs])
            #expect(status.lastStatus == .ok)
            #expect(status.skillsCount == 2)
            #expect(status.jobsCount == 2)
            #expect(status.transport == .remote)
            var skills = try await h.service.mirroredSkills(tenantID: h.tenantID)
            #expect(skills.map(\.name) == ["a", "b"])
            #expect(skills[1].enabled == false)

            await h.transport.setSkills([skill("b", enabled: true, description: "changed"), skill("c")])
            await h.transport.setJobs([job("j2", name: "Two renamed", paused: true)])
            status = try await h.service.sync(tenantID: h.tenantID, scopes: [.skills, .jobs])
            skills = try await h.service.mirroredSkills(tenantID: h.tenantID)
            #expect(skills.map(\.name) == ["b", "c"])
            #expect(skills[0].enabled == true)
            #expect(skills[0].description == "changed")
            let jobs = try await HermesMirroredJob.query(on: fluent.db(), tenantID: h.tenantID).all()
            #expect(jobs.map(\.hermesJobID) == ["j2"])
            #expect(jobs[0].name == "Two renamed")
            #expect(jobs[0].paused == true)
            #expect(status.jobsCount == 1)
        }
    }

    @Test
    func `sync records a partial failure when one scope fails and keeps the other`() async throws {
        try await withTestFluent(label: "lv.test.mirror.partial") { fluent in
            let h = try await makeHarness(fluent: fluent)
            await h.transport.setSkills([skill("a")])
            await h.transport.fail("listJobs", with: .dashboardAuthModeUnsupported)
            let status = try await h.service.sync(tenantID: h.tenantID, scopes: [.skills, .jobs])
            #expect(status.lastStatus == .partial)
            #expect(status.skillsCount == 1)
            #expect(status.lastError?.contains("hermes_dashboard_auth_mode_unsupported") == true)

            await h.transport.fail("listSkills", with: .dashboardUnreachable("x"))
            let failed = try await h.service.sync(tenantID: h.tenantID, scopes: [.skills, .jobs])
            #expect(failed.lastStatus == .failed)
        }
    }

    @Test
    func `toggleSkill reaches Hermes and persists the flag`() async throws {
        try await withTestFluent(label: "lv.test.mirror.toggle") { fluent in
            let h = try await makeHarness(fluent: fluent)
            await h.transport.setSkills([skill("a")])
            _ = try await h.service.sync(tenantID: h.tenantID, scopes: [.skills])
            let toggled = try await h.service.toggleSkill(tenantID: h.tenantID, name: "a", enabled: false)
            #expect(toggled.enabled == false)
            #expect(await h.transport.recordedCalls().contains("toggleSkill:a:false"))
            #expect(try await h.service.mirroredSkills(tenantID: h.tenantID).first?.enabled == false)
            await #expect(throws: HTTPError.self) {
                try await h.service.toggleSkill(tenantID: h.tenantID, name: "missing", enabled: true)
            }
        }
    }

    @Test
    func `jobs are live when Hermes answers and a snapshot otherwise`() async throws {
        try await withTestFluent(label: "lv.test.mirror.jobs") { fluent in
            let h = try await makeHarness(fluent: fluent)
            await h.transport.setJobs([job("j1", name: "One")])
            let live = try await h.service.jobs(tenantID: h.tenantID)
            #expect(live.source == .live)
            #expect(live.jobs.map(\.hermesJobID) == ["j1"])

            await h.transport.fail("listJobs", with: .dashboardUnreachable("down"))
            let snapshot = try await h.service.jobs(tenantID: h.tenantID)
            #expect(snapshot.source == .snapshot)
            #expect(snapshot.jobs.map(\.hermesJobID) == ["j1"])
        }
    }

    // MARK: - Vault

    @Test
    func `detectVault finds the kb root by manifest, obsidian-vault child, or kb-config pointer`() async throws {
        try await withTestFluent(label: "lv.test.mirror.detect") { fluent in
            let h = try await makeHarness(fluent: fluent)
            await h.transport.addFile("/home/hermes/kb/.kb/manifest.json", "{}")
            #expect(try await h.service.detectVault(transport: h.transport, preferred: nil) == "/home/hermes/kb")

            let h2 = try await makeHarness(fluent: fluent)
            await h2.transport.addFile("/home/hermes/obsidian-vault/Fernando/raw/a.md", "# a")
            await h2.transport.addDirectory("/home/hermes/obsidian-vault/Fernando/wiki")
            #expect(try await h2.service.detectVault(transport: h2.transport, preferred: nil) == "/home/hermes/obsidian-vault/Fernando")

            let h3 = try await makeHarness(fluent: fluent)
            await h3.transport.addFile("/home/hermes/kb-config.json", #"{"kb_path":"/srv/notes"}"#)
            await h3.transport.addFile("/srv/notes/.kb/manifest.json", "{}")
            #expect(try await h3.service.detectVault(transport: h3.transport, preferred: nil) == "/srv/notes")

            let h4 = try await makeHarness(fluent: fluent)
            #expect(try await h4.service.detectVault(transport: h4.transport, preferred: "/gone") == nil)
        }
    }

    @Test
    func `importVault ingests markdown, skips hidden dirs, resumes from the cursor and reports counts`() async throws {
        var limits = HermesMirrorService.Limits()
        limits.readPause = .zero
        limits.vaultFilesPerRun = 2
        try await withTestFluent(label: "lv.test.mirror.import") { fluent in
            let h = try await makeHarness(fluent: fluent, limits: limits)
            await h.transport.addFile("/home/hermes/kb/.kb/manifest.json", "{}")
            await h.transport.addFile("/home/hermes/kb/raw/a.md", "# A\nalpha")
            await h.transport.addFile("/home/hermes/kb/raw/b.md", "# B\nbeta")
            await h.transport.addFile("/home/hermes/kb/wiki/c.md", "# C\ngamma")
            await h.transport.addFile("/home/hermes/kb/raw/image.png", "binary")
            await h.transport.addFile("/home/hermes/kb/.obsidian/workspace.md", "ignored")
            await h.transport.addFile("/home/hermes/kb/.trash/old.md", "ignored")

            let first = try await h.service.importVault(tenantID: h.tenantID, requestedPath: nil)
            #expect(first.vaultPath == "/home/hermes/kb")
            #expect(first.imported == 2)
            #expect(first.truncated == true)
            #expect(first.cursor != nil)
            #expect(try await h.service.hasPendingVaultImport(tenantID: h.tenantID) == true)

            let second = try await h.service.importVault(tenantID: h.tenantID, requestedPath: nil)
            #expect(second.imported == 1)
            #expect(second.truncated == false)
            #expect(second.cursor == nil)
            #expect(second.scanned == 3)

            let status = try await h.service.status(tenantID: h.tenantID)
            #expect(status.vaultState == .imported)
            #expect(status.vaultFilesCount == 3)
            let files = try await VaultFile.query(on: fluent.db(), tenantID: h.tenantID).all()
            #expect(files.count == 3)
            #expect(files.allSatisfy { $0.metadata?.provenance == HermesMirrorService.vaultProvenance })
            #expect(!files.contains { $0.path.contains("obsidian") || $0.path.contains("trash") })

            // Unchanged re-import is a no-op (still paced by the per-run cap).
            let third = try await h.service.importVault(tenantID: h.tenantID, requestedPath: nil)
            #expect(third.imported == 0)
            #expect(third.skipped == 2)
            #expect(third.truncated == true)
        }
    }

    @Test
    func `importVault rejects traversal and unknown paths`() async throws {
        try await withTestFluent(label: "lv.test.mirror.import.reject") { fluent in
            let h = try await makeHarness(fluent: fluent)
            await #expect(throws: HermesMirrorTransportError.invalidPath("/home/../etc")) {
                try await h.service.importVault(tenantID: h.tenantID, requestedPath: "/home/../etc")
            }
            await #expect(throws: HTTPError.self) {
                try await h.service.importVault(tenantID: h.tenantID, requestedPath: "/nowhere")
            }
            await #expect(throws: HTTPError.self) {
                try await h.service.importVault(tenantID: h.tenantID, requestedPath: nil)
            }
        }
    }

    @Test
    func `importVault skips files over the size cap`() async throws {
        var limits = HermesMirrorService.Limits()
        limits.readPause = .zero
        limits.maxFileBytes = 10
        try await withTestFluent(label: "lv.test.mirror.import.cap") { fluent in
            let h = try await makeHarness(fluent: fluent, limits: limits)
            await h.transport.addFile("/home/hermes/kb/.kb/manifest.json", "{}")
            await h.transport.addFile("/home/hermes/kb/raw/small.md", "# s")
            await h.transport.addFile("/home/hermes/kb/raw/big.md", String(repeating: "x", count: 64))
            let result = try await h.service.importVault(tenantID: h.tenantID, requestedPath: "/home/hermes/kb")
            #expect(result.imported == 1)
            #expect(result.skipped == 1)
        }
    }

    @Test
    func `createVault builds the skeleton, installs missing kb skills, and is idempotent`() async throws {
        try await withTestFluent(label: "lv.test.mirror.create") { fluent in
            let h = try await makeHarness(fluent: fluent)
            await h.transport.setSkills([skill("kb-ingest")])
            let created = try await h.service.createVault(tenantID: h.tenantID)
            #expect(created.alreadyExisted == false)
            #expect(created.vaultPath == "/home/hermes/kb")
            #expect(created.createdDirectories == ["/home/hermes/kb", "/home/hermes/kb/raw", "/home/hermes/kb/wiki", "/home/hermes/kb/.kb"])
            #expect(created.installedSkills == ["kb-compile"])
            let files = await h.transport.fileContents()
            #expect(files["/home/hermes/kb/.kb/manifest.json"]?.contains(#""created_by" : "luminavault""#) == true)
            #expect(files["/home/hermes/kb/README.md"]?.contains("LuminaVault knowledge base") == true)
            let status = try await h.service.status(tenantID: h.tenantID)
            #expect(status.vaultState == .created)
            #expect(status.vaultPath == "/home/hermes/kb")

            let again = try await h.service.createVault(tenantID: h.tenantID)
            #expect(again.alreadyExisted == true)
            #expect(again.createdDirectories.isEmpty)
            #expect(again.installedSkills.isEmpty)
        }
    }

    // MARK: - Sessions

    @Test
    func `importSessions writes transcripts, skips empty sessions, triggers compile and honours the high-water mark`() async throws {
        try await withTestFluent(label: "lv.test.mirror.sessions") { fluent in
            let h = try await makeHarness(fluent: fluent)
            let base = Date(timeIntervalSince1970: 1_756_800_000)
            await h.transport.setSessions([
                HermesMirrorSession(id: "s-new", title: "Planning", source: "cli", startedAt: base.addingTimeInterval(7200), lastActiveAt: base.addingTimeInterval(7300), messageCount: 2),
                HermesMirrorSession(id: "s-empty", title: nil, source: "cli", startedAt: base, lastActiveAt: base, messageCount: 0),
                HermesMirrorSession(id: "s-old", title: nil, source: "telegram", startedAt: base.addingTimeInterval(-86400), lastActiveAt: base.addingTimeInterval(-86000), messageCount: 1),
            ])
            await h.transport.setMessages("s-new", [
                HermesMirrorSessionMessage(role: "user", content: "What is the plan?", timestamp: base),
                HermesMirrorSessionMessage(role: "assistant", content: "Ship the mirror.", timestamp: base.addingTimeInterval(1)),
            ])
            await h.transport.setMessages("s-old", [HermesMirrorSessionMessage(role: "user", content: "old note", timestamp: nil)])

            let first = try await h.service.importSessions(tenantID: h.tenantID)
            #expect(first.sessionsImported == 2)
            #expect(first.sessionsSkipped == 1)
            #expect(first.filesWritten == 2)
            #expect(first.truncated == false)
            #expect(first.compileTriggered == true)
            #expect(await h.compile.recorded().first?.count == 2)

            let files = try await VaultFile.query(on: fluent.db(), tenantID: h.tenantID).all()
            #expect(files.count == 2)
            #expect(files.allSatisfy { $0.metadata?.provenance == HermesMirrorService.sessionProvenance })
            #expect(files.contains { $0.path.contains("sessions/2025-09-02-s-new") })
            #expect(try await h.service.status(tenantID: h.tenantID).sessionsImported == 2)

            // Nothing newer than the high-water mark: the second pass stops at the first old session.
            let second = try await h.service.importSessions(tenantID: h.tenantID)
            #expect(second.sessionsImported == 0)
            #expect(second.filesWritten == 0)
            #expect(second.compileTriggered == false)
            #expect(await h.compile.recorded().count == 1)

            // A newer session appears: only it is imported.
            await h.transport.setSessions([
                HermesMirrorSession(id: "s-newer", title: "Later", source: "cli", startedAt: base.addingTimeInterval(9000), lastActiveAt: base.addingTimeInterval(9100), messageCount: 1),
                HermesMirrorSession(id: "s-new", title: "Planning", source: "cli", startedAt: base.addingTimeInterval(7200), lastActiveAt: base.addingTimeInterval(7300), messageCount: 2),
            ])
            await h.transport.setMessages("s-newer", [HermesMirrorSessionMessage(role: "user", content: "again", timestamp: nil)])
            let third = try await h.service.importSessions(tenantID: h.tenantID)
            #expect(third.sessionsImported == 1)
            #expect(try await VaultFile.query(on: fluent.db(), tenantID: h.tenantID).count() == 3)
        }
    }

    @Test
    func `importSessions caps a run and resumes from the offset cursor`() async throws {
        var limits = HermesMirrorService.Limits()
        limits.readPause = .zero
        limits.sessionsPerRun = 2
        limits.sessionPageSize = 2
        try await withTestFluent(label: "lv.test.mirror.sessions.cursor") { fluent in
            let h = try await makeHarness(fluent: fluent, limits: limits)
            let base = Date(timeIntervalSince1970: 1_756_800_000)
            var sessions: [HermesMirrorSession] = []
            for index in 0 ..< 5 {
                let id = "s\(index)"
                sessions.append(HermesMirrorSession(id: id, title: id, source: "cli", startedAt: base, lastActiveAt: base.addingTimeInterval(Double(100 - index)), messageCount: 1))
                await h.transport.setMessages(id, [HermesMirrorSessionMessage(role: "user", content: "m\(index)", timestamp: nil)])
            }
            await h.transport.setSessions(sessions)
            let first = try await h.service.importSessions(tenantID: h.tenantID)
            #expect(first.sessionsImported == 2)
            #expect(first.truncated == true)
            #expect(first.cursor?.contains(#""offset":2"#) == true)
            let second = try await h.service.importSessions(tenantID: h.tenantID)
            #expect(second.sessionsImported == 2)
            #expect(second.truncated == true)
            let third = try await h.service.importSessions(tenantID: h.tenantID)
            #expect(third.sessionsImported == 1)
            #expect(third.truncated == false)
            #expect(try await VaultFile.query(on: fluent.db(), tenantID: h.tenantID).count() == 5)
        }
    }

    // MARK: - Compile job

    @Test
    func `installCompileJob creates the nightly job once and remembers its id`() async throws {
        try await withTestFluent(label: "lv.test.mirror.compile-job") { fluent in
            let h = try await makeHarness(fluent: fluent)
            await h.transport.addFile("/home/hermes/kb/.kb/manifest.json", "{}")
            let created = try await h.service.installCompileJob(tenantID: h.tenantID)
            #expect(created.created == true)
            #expect(created.schedule == HermesMirrorService.compileJobSchedule)
            let jobs = await h.transport.jobList()
            #expect(jobs.count == 1)
            #expect(jobs[0].name == HermesMirrorService.compileJobName)
            #expect(jobs[0].prompt?.contains("/home/hermes/kb") == true)
            #expect(try await h.service.status(tenantID: h.tenantID).compileJobID == created.jobID)

            let again = try await h.service.installCompileJob(tenantID: h.tenantID)
            #expect(again.created == false)
            #expect(again.jobID == created.jobID)
            #expect(await h.transport.jobList().count == 1)
        }
    }

    @Test
    func `status for a tenant that never synced is empty`() async throws {
        try await withTestFluent(label: "lv.test.mirror.status") { fluent in
            let h = try await makeHarness(fluent: fluent, kind: .managed)
            let status = try await h.service.status(tenantID: h.tenantID)
            #expect(status.lastStatus == .never)
            #expect(status.transport == .managed)
            #expect(status.skillsCount == 0)
            #expect(status.vaultState == .absent)
            #expect(status.sessionsImported == 0)
        }
    }

    // MARK: - Collect (Phase 2)

    private func run(
        _ key: String,
        _ started: TimeInterval,
        status: HermesJobRunStatus = .ok,
        error: String? = nil,
        tokensIn: Int? = nil,
        tokensOut: Int? = nil
    ) -> HermesMirrorJobRun {
        HermesMirrorJobRun(
            key: key, status: status,
            startedAt: Date(timeIntervalSince1970: started),
            finishedAt: status == .running ? nil : Date(timeIntervalSince1970: started + 60),
            error: error, tokensIn: tokensIn, tokensOut: tokensOut
        )
    }

    @Test
    func `collect stores finished runs, files the output and logs a hermes skill run`() async throws {
        try await withTestFluent(label: "lv.test.mirror.collect") { fluent in
            let h = try await makeHarness(fluent: fluent)
            await h.transport.setJobs([job("j1", name: "Daily Digest")])
            _ = try await h.service.sync(tenantID: h.tenantID, scopes: [.jobs])
            let rawAfterSync = try #require(await HermesMirroredJob.query(on: fluent.db(), tenantID: h.tenantID).first()).raw
            await h.transport.setRuns("j1", [run("cron_j1_2", 1_756_800_000, tokensIn: 12, tokensOut: 34)])
            await h.transport.setRunOutput("j1", "cron_j1_2", "# Tuesday brief\n\nAll quiet.\n")

            let result = try await h.service.collectJobRuns(tenantID: h.tenantID, jobID: "j1")
            #expect(result.fetched == 1)
            #expect(result.inserted == 1)
            #expect(result.skipped == 0)
            #expect(result.filesWritten == 1)
            #expect(result.truncated == false)
            #expect(result.highWaterMark == Date(timeIntervalSince1970: 1_756_800_000))

            let rows = try await HermesJobRun.query(on: fluent.db(), tenantID: h.tenantID).all()
            #expect(rows.count == 1)
            #expect(rows[0].hermesRunKey == "cron_j1_2")
            #expect(rows[0].status == HermesJobRunStatus.ok.rawValue)
            #expect(rows[0].output == "# Tuesday brief\n\nAll quiet.\n")
            #expect(rows[0].vaultFileID != nil)
            #expect(rows[0].skillRunLogID != nil)
            #expect(rows[0].tokens == HermesJobRunTokensDTO(input: 12, output: 34))

            // The output is a vault file under raw/jobs/<job-slug>/<stamp>.md.
            let vaultFileID = try #require(rows[0].vaultFileID)
            let file = try #require(await VaultFile.find(vaultFileID, on: fluent.db()))
            #expect(file.path.hasSuffix("raw/jobs/daily-digest/2025-09-02-0800.md"))
            #expect(file.metadata?.provenance == HermesMirrorService.jobProvenance)

            // …and a `skill_run_log` row with source `hermes` for the feed.
            let sql = try #require(fluent.db() as? any SQLDatabase)
            struct LogRow: Decodable { let source: String; let name: String; let status: String; let markdown: String? }
            let logs = try await sql.raw("SELECT source, name, status, markdown FROM skill_run_log WHERE tenant_id = \(bind: h.tenantID)")
                .all(decoding: LogRow.self)
            #expect(logs.count == 1)
            #expect(logs[0].source == SkillSource.hermes.rawValue)
            #expect(logs[0].name == "Daily Digest")
            #expect(logs[0].status == SkillRunStatus.success.rawValue)
            #expect(logs[0].markdown == "# Tuesday brief\n\nAll quiet.\n")

            let listed = try await h.service.jobRuns(tenantID: h.tenantID, jobID: "j1", limit: 10)
            #expect(listed.runs.map(\.runKey) == ["cron_j1_2"])
            #expect(listed.collectedAt != nil)
            #expect(listed.runs[0].tokens == HermesJobRunTokensDTO(input: 12, output: 34))
            // The listing resolves the vault path the run was filed at, so a
            // client can open the output without a second round trip.
            #expect(listed.runs[0].vaultFilePath?.hasSuffix("raw/jobs/daily-digest/2025-09-02-0800.md") == true)

            // The pass writes only the two collect columns, so the mirrored
            // job's `raw` jsonb is byte-identical afterwards. Saving the whole
            // row instead would re-encode it and corrupt it a little more on
            // every tick — PostgresNIO hands a `jsonb` column back to a
            // single-value-container type like `JSONValue` as its raw *text*,
            // so a load→save cycle wraps the document in another JSON string.
            let mirrored = try #require(await HermesMirroredJob.query(on: fluent.db(), tenantID: h.tenantID).first())
            #expect(mirrored.raw == rawAfterSync)
            #expect(mirrored.runsHighWaterAt == Date(timeIntervalSince1970: 1_756_800_000))
        }
    }

    @Test
    func `collecting the same run twice inserts nothing and reads no output`() async throws {
        try await withTestFluent(label: "lv.test.mirror.collect.idem") { fluent in
            let h = try await makeHarness(fluent: fluent)
            await h.transport.setJobs([job("j1", name: "Digest")])
            _ = try await h.service.sync(tenantID: h.tenantID, scopes: [.jobs])
            await h.transport.setRuns("j1", [run("cron_j1_1", 1_756_800_000)])
            await h.transport.setRunOutput("j1", "cron_j1_1", "# One\n")
            _ = try await h.service.collectJobRuns(tenantID: h.tenantID, jobID: "j1")

            let second = try await h.service.collectJobRuns(tenantID: h.tenantID, jobID: "j1")
            #expect(second.inserted == 0)
            #expect(second.skipped == 1)
            #expect(second.filesWritten == 0)
            #expect(try await HermesJobRun.query(on: fluent.db(), tenantID: h.tenantID).count() == 1)
            // The high-water fast path means the second pass never re-read the
            // output — one `jobRuns` call, one `jobRunOutput` call in total.
            let calls = await h.transport.recordedCalls()
            #expect(calls.filter { $0.hasPrefix("jobRunOutput") }.count == 1)
            #expect(calls.filter { $0.hasPrefix("jobRuns") }.count == 2)

            // A newer run gets through the fast path and is collected.
            await h.transport.setRuns("j1", [run("cron_j1_1", 1_756_800_000), run("cron_j1_2", 1_756_803_600)])
            await h.transport.setRunOutput("j1", "cron_j1_2", "# Two\n")
            let third = try await h.service.collectJobRuns(tenantID: h.tenantID, jobID: "j1")
            #expect(third.inserted == 1)
            #expect(third.skipped == 1)
            #expect(try await HermesJobRun.query(on: fluent.db(), tenantID: h.tenantID).count() == 2)
        }
    }

    @Test
    func `running runs are left for later and failed runs are stored without a file`() async throws {
        try await withTestFluent(label: "lv.test.mirror.collect.status") { fluent in
            let h = try await makeHarness(fluent: fluent)
            await h.transport.setJobs([job("j1", name: "Digest")])
            _ = try await h.service.sync(tenantID: h.tenantID, scopes: [.jobs])
            await h.transport.setRuns("j1", [
                run("in-flight", 1_756_807_200, status: .running),
                run("failed", 1_756_800_000, status: .error, error: "provider timeout"),
                run("empty", 1_756_803_600),
            ])
            // `empty` finished but Hermes kept nothing worth filing.
            await h.transport.setRunOutput("j1", "empty", "   \n")

            let result = try await h.service.collectJobRuns(tenantID: h.tenantID, jobID: "j1")
            #expect(result.fetched == 3)
            #expect(result.inserted == 2)
            #expect(result.skipped == 1)
            #expect(result.filesWritten == 0)

            let rows = try await HermesJobRun.query(on: fluent.db(), tenantID: h.tenantID).sort(\.$startedAt).all()
            #expect(rows.map(\.hermesRunKey) == ["failed", "empty"])
            #expect(rows[0].status == HermesJobRunStatus.error.rawValue)
            #expect(rows[0].error == "provider timeout")
            #expect(rows[0].output == nil)
            #expect(rows[0].vaultFileID == nil)
            #expect(rows[1].output == nil)
            // The in-flight run is not below the water mark, so a later pass
            // still picks it up once it finishes.
            let job = try #require(await HermesMirroredJob.query(on: fluent.db(), tenantID: h.tenantID).first())
            #expect(job.runsHighWaterAt == Date(timeIntervalSince1970: 1_756_803_600))

            await h.transport.setRuns("j1", [run("in-flight", 1_756_807_200)])
            await h.transport.setRunOutput("j1", "in-flight", "# Landed\n")
            #expect(try await h.service.collectJobRuns(tenantID: h.tenantID, jobID: "j1").inserted == 1)
        }
    }

    @Test
    func `collect caps runs per tick and reports truncation`() async throws {
        try await withTestFluent(label: "lv.test.mirror.collect.cap") { fluent in
            let h = try await makeHarness(fluent: fluent)
            await h.transport.setJobs([job("j1", name: "Chatty")])
            _ = try await h.service.sync(tenantID: h.tenantID, scopes: [.jobs])
            let cap = HermesMirrorService.collectLimits.runsPerJobPerTick
            var many: [HermesMirrorJobRun] = []
            for index in 0 ..< (cap + 10) {
                many.append(run("run-\(index)", 1_756_800_000 + Double(index) * 60))
            }
            await h.transport.setRuns("j1", many)

            let result = try await h.service.collectJobRuns(tenantID: h.tenantID, jobID: "j1")
            #expect(result.fetched == cap)
            #expect(result.inserted == cap)
            #expect(result.truncated == true)
            #expect(try await HermesJobRun.query(on: fluent.db(), tenantID: h.tenantID).count() == cap)
        }
    }

    @Test
    func `collectAllJobRuns isolates a failing job and an unknown job is a 404`() async throws {
        try await withTestFluent(label: "lv.test.mirror.collect.all") { fluent in
            let h = try await makeHarness(fluent: fluent)
            await h.transport.setJobs([job("j1", name: "Good"), job("j2", name: "Broken")])
            _ = try await h.service.sync(tenantID: h.tenantID, scopes: [.jobs])
            await h.transport.setRuns("j1", [run("cron_j1_1", 1_756_800_000)])
            await h.transport.setRunOutput("j1", "cron_j1_1", "# Fine\n")
            await h.transport.fail("jobRuns:j2", with: .dashboardUnreachable("boom"))

            let summary = try await h.service.collectAllJobRuns(tenantID: h.tenantID)
            #expect(summary.jobs == 1)
            #expect(summary.failed == 1)
            #expect(summary.inserted == 1)
            #expect(summary.filesWritten == 1)
            #expect(try await HermesJobRun.query(on: fluent.db(), tenantID: h.tenantID).count() == 1)

            do {
                _ = try await h.service.collectJobRuns(tenantID: h.tenantID, jobID: "nope")
                Issue.record("expected hermes_job_not_found")
            } catch let error as HTTPError {
                #expect(error.status == .notFound)
                #expect(error.body == "hermes_job_not_found")
            }
        }
    }
}

/// Pure helpers on the service (no database).
@Suite(.disabled(if: IntegrationTestEnv.runIntegrationOnly))
struct HermesMirrorServiceHelperTests {
    @Test
    func `session markdown renders a transcript and truncates at the cap`() throws {
        let session = HermesMirrorSession(id: "abc", title: "Plan", source: "cli", startedAt: Date(timeIntervalSince1970: 0), lastActiveAt: nil, messageCount: 2)
        let messages = [
            HermesMirrorSessionMessage(role: "user", content: "hello", timestamp: nil),
            HermesMirrorSessionMessage(role: "tool", content: "ignored", timestamp: nil),
            HermesMirrorSessionMessage(role: "assistant", content: "world", timestamp: nil),
        ]
        let markdown = try #require(HermesMirrorService.sessionMarkdown(session: session, messages: messages, maxBytes: 4096))
        #expect(markdown.hasPrefix("# Plan\n"))
        #expect(markdown.contains("## User\n\nhello"))
        #expect(markdown.contains("## Assistant\n\nworld"))
        #expect(!markdown.contains("ignored"))
        let truncated = try #require(HermesMirrorService.sessionMarkdown(session: session, messages: messages, maxBytes: 120))
        #expect(truncated.contains("Transcript truncated"))
        #expect(HermesMirrorService.sessionMarkdown(session: session, messages: [HermesMirrorSessionMessage(role: "tool", content: "x", timestamp: nil)], maxBytes: 100) == nil)
    }

    @Test
    func `session file names are dated and sanitised`() {
        let session = HermesMirrorSession(id: "ab/../c d", title: nil, source: nil, startedAt: Date(timeIntervalSince1970: 1_756_800_000), lastActiveAt: nil, messageCount: 1)
        #expect(HermesMirrorService.sessionFileName(session) == "sessions/2025-09-02-abcd.md")
    }

    @Test
    func `compile prompt names the vault path and the skill`() {
        #expect(HermesMirrorService.compilePrompt(vaultPath: "/kb").contains("/kb-compile"))
        #expect(HermesMirrorService.compilePrompt(vaultPath: "/kb").contains("`/kb`"))
        #expect(HermesMirrorService.compilePrompt(vaultPath: nil).contains("Locate the knowledge base"))
    }

    @Test
    func `the vault path slugifies the job name and stamps the run start in UTC`() {
        let row = HermesMirroredJob()
        row.hermesJobID = "8628eaf81dda"
        row.name = "Daily Digest — Morning"
        let started = Date(timeIntervalSince1970: 1_756_800_000)
        #expect(
            HermesMirrorService.jobOutputVaultPath(job: row, run: HermesMirrorJobRun(key: "k", status: .ok, startedAt: started))
                == "raw/jobs/daily-digest-morning/2025-09-02-0800.md"
        )
        row.name = "   "
        #expect(
            HermesMirrorService.jobOutputVaultPath(job: row, run: HermesMirrorJobRun(key: "k", status: .ok, startedAt: started))
                == "raw/jobs/8628eaf81dda/2025-09-02-0800.md"
        )
        #expect(HermesMirrorService.stamp(Date(timeIntervalSince1970: 0)) == "1970-01-01-0000")
    }

    @Test
    func `status DTO maps the state row`() {
        let state = HermesMirrorState(tenantID: UUID())
        state.lastStatus = "partial"
        state.vaultState = "imported"
        state.skillsCount = 3
        state.compileJobID = "j"
        let dto = HermesMirrorService.statusDTO(state: state, kind: .remote, dashboard: nil)
        #expect(dto.lastStatus == .partial)
        #expect(dto.vaultState == .imported)
        #expect(dto.skillsCount == 3)
        #expect(dto.compileJobID == "j")
        #expect(HermesMirrorService.statusDTO(state: nil, kind: .managed, dashboard: nil).lastStatus == .never)
    }
}
