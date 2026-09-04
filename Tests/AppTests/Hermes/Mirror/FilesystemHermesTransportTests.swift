@testable import App
import Foundation
import Logging
import LuminaVaultShared
import Testing

/// Hermes Mirror task 1 — the managed transport reads and writes the Hermes
/// home on the shared PVC and never leaves it.
@Suite(.disabled(if: IntegrationTestEnv.runIntegrationOnly))
struct FilesystemHermesTransportTests {
    private static let logger = Logger(label: "test.hermes-fs")

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lv-hermes-mirror-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func write(_ root: URL, _ relative: String, _ content: String) throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url)
    }

    @Test
    func `lists skills from SKILL.md with frontmatter descriptions and disabled config`() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root, "skills/kb-compile/SKILL.md", "---\nname: kb-compile\ndescription: Compile raw into wiki\ntrigger: /kb-compile\n---\n# body\n")
        try write(root, "skills/weather/SKILL.md", "Fetch the weather.\n")
        try write(root, "skills/.hidden/SKILL.md", "nope")
        try write(root, "config.yaml", "model:\n  default: gpt\nskills:\n  disabled:\n    - weather\n")
        let transport = FilesystemHermesTransport(rootPath: root.path, logger: Self.logger)
        let skills = try await transport.listSkills()
        #expect(skills.map(\.name) == ["kb-compile", "weather"])
        #expect(skills[0].description == "Compile raw into wiki")
        #expect(skills[0].enabled == true)
        #expect(skills[0].contentHash?.count == 64)
        #expect(skills[1].description == "Fetch the weather.")
        #expect(skills[1].enabled == false)
        #expect(try await transport.skillContent(name: "weather") == "Fetch the weather.\n")
        #expect(try await transport.status().reachable == true)
    }

    @Test
    func `toggleSkill rewrites skills.disabled in config.yaml and keeps other keys`() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root, "skills/a/SKILL.md", "A")
        try write(root, "config.yaml", "model:\n  default: gpt\nskills:\n  disabled: []\n")
        let transport = FilesystemHermesTransport(rootPath: root.path, logger: Self.logger)
        try await transport.toggleSkill(name: "a", enabled: false)
        var skills = try await transport.listSkills()
        #expect(skills[0].enabled == false)
        let config = FilesystemHermesTransport.loadConfig(configURL: root.appendingPathComponent("config.yaml"))
        #expect((config["model"] as? [String: Any])?["default"] as? String == "gpt")
        try await transport.toggleSkill(name: "a", enabled: true)
        skills = try await transport.listSkills()
        #expect(skills[0].enabled == true)
        await #expect(throws: HermesMirrorTransportError.invalidPath("skill:../x")) {
            try await transport.toggleSkill(name: "../x", enabled: true)
        }
    }

    @Test
    func `createSkill writes SKILL.md under skills`() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = FilesystemHermesTransport(rootPath: root.path, logger: Self.logger)
        try await transport.createSkill(name: "kb-ingest", content: "---\nname: kb-ingest\ndescription: Ingest\n---\n")
        let written = try String(contentsOf: root.appendingPathComponent("skills/kb-ingest/SKILL.md"), encoding: .utf8)
        #expect(written.contains("description: Ingest"))
        #expect(try await transport.listSkills().map(\.name) == ["kb-ingest"])
    }

    @Test
    func `createJob appends to cron jobs json in the scheduler shape`() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root, "cron/jobs.json", #"{"jobs":[{"id":"old1","name":"Existing","schedule":{"kind":"cron","expr":"0 9 * * *","display":"0 9 * * *"},"enabled":true}],"updated_at":"x"}"#)
        let fixed = Date(timeIntervalSince1970: 1_756_800_000)
        let transport = FilesystemHermesTransport(rootPath: root.path, logger: Self.logger, clock: { fixed })
        let job = try await transport.createJob(HermesMirrorJobSpec(name: "luminavault-nightly-compile", schedule: "0 3 * * *", prompt: "compile", deliver: "origin", skills: ["kb-compile"]))
        #expect(job.name == "luminavault-nightly-compile")
        #expect(job.schedule == "0 3 * * *")
        #expect(job.id.count == 12)
        #expect(job.nextRunAt != nil)
        let jobs = try await transport.listJobs()
        #expect(jobs.map(\.id) == ["old1", job.id])
        let data = try Data(contentsOf: root.appendingPathComponent("cron/jobs.json"))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let rows = try #require(object["jobs"] as? [[String: Any]])
        #expect(rows[1]["state"] as? String == "scheduled")
        #expect(rows[1]["deliver"] as? String == "origin")
        #expect((rows[1]["skills"] as? [String]) == ["kb-compile"])
        #expect((rows[1]["schedule"] as? [String: Any])?["expr"] as? String == "0 3 * * *")
        await #expect(throws: (any Error).self) {
            try await transport.createJob(HermesMirrorJobSpec(name: "bad", schedule: "not a cron", prompt: "", deliver: "origin", skills: []))
        }
    }

    @Test
    func `nextRun finds the next matching minute`() throws {
        let expression = try CronExpression("0 3 * * *")
        let from = Date(timeIntervalSince1970: 1_756_800_000)
        let next = try #require(FilesystemHermesTransport.nextRun(after: from, expression: expression))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let components = calendar.dateComponents([.hour, .minute], from: next)
        #expect(components.hour == 3)
        #expect(components.minute == 0)
        #expect(next > from)
    }

    @Test
    func `filesystem operations stay inside the root`() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = FilesystemHermesTransport(rootPath: root.path, logger: Self.logger)
        let kb = root.appendingPathComponent("kb").path
        try await transport.mkdir(path: kb + "/raw")
        try await transport.writeText(path: kb + "/raw/note.md", content: "# Note\n")
        #expect(try await transport.readText(path: kb + "/raw/note.md") == "# Note\n")
        let entries = try await transport.listFiles(path: kb)
        #expect(entries == [HermesMirrorFileEntry(name: "raw", path: kb + "/raw", isDirectory: true)])

        let outside = root.deletingLastPathComponent().appendingPathComponent("elsewhere").path
        await #expect(throws: HermesMirrorTransportError.invalidPath(outside)) {
            try await transport.listFiles(path: outside)
        }
        await #expect(throws: HermesMirrorTransportError.invalidPath(kb + "/../../etc/passwd")) {
            try await transport.readText(path: kb + "/../../etc/passwd")
        }
        await #expect(throws: HermesMirrorTransportError.notFound(kb + "/nope")) {
            try await transport.writeText(path: kb + "/nope/x.md", content: "x")
        }
        await #expect(throws: HermesMirrorTransportError.notFound(kb + "/missing")) {
            try await transport.listFiles(path: kb + "/missing")
        }
    }

    @Test
    func `sessions are unsupported without a gateway client`() async {
        let transport = FilesystemHermesTransport(rootPath: "/tmp/lv-none", logger: Self.logger)
        await #expect(throws: HermesMirrorTransportError.unsupported("sessions")) {
            try await transport.listSessions(offset: 0, limit: 10)
        }
    }

    @Test
    func `gateway sessions client uses the api_server paths with the auth header`() async throws {
        let http = StubHermesHTTP()
        http.respond("GET", "/api/sessions", json: #"{"sessions":[{"id":"s1","message_count":2}],"total":1}"#)
        http.respond("GET", "/api/sessions/s1/messages", json: #"{"messages":[{"role":"user","content":"hi"}]}"#)
        let baseURL = try #require(URL(string: "http://hermes:8642"))
        let client = HermesGatewaySessionsClient(baseURL: baseURL, authHeader: "Bearer key", http: http, logger: Self.logger)
        let transport = FilesystemHermesTransport(rootPath: "/tmp/lv-none", sessions: client, logger: Self.logger)
        let page = try await transport.listSessions(offset: 0, limit: 5)
        #expect(page.sessions.map(\.id) == ["s1"])
        let messages = try await transport.sessionMessages(id: "s1")
        #expect(messages.first?.content == "hi")
        #expect(http.requests.first?.url.hasPrefix("http://hermes:8642/api/sessions?") == true)
        #expect(http.requests.first?.headers.contains { $0.0 == "Authorization" && $0.1 == "Bearer key" } == true)
    }
}
