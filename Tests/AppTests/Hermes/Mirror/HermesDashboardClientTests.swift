@testable import App
import Foundation
import Hummingbird
import Logging
import LuminaVaultShared
import Testing

/// Hermes Mirror task 1 — the dashboard client speaks `web_server.py`'s
/// `/api/*` contract, detects the OAuth-only auth mode, caps and validates
/// paths, and never leaks the token.
@Suite(.disabled(if: IntegrationTestEnv.runIntegrationOnly))
struct HermesDashboardClientTests {
    private static let logger = Logger(label: "test.hermes-dashboard")

    private func makeClient(_ http: StubHermesHTTP, baseURL: String = "http://127.0.0.1:9119/") -> HermesDashboardClient {
        HermesDashboardClient(
            baseURL: baseURL,
            token: "dash-secret",
            ssrfGuard: SSRFGuard(allowPrivateRanges: true, requireHTTPS: false, allowTailnetHTTP: true),
            http: http,
            logger: Self.logger
        )
    }

    @Test
    func `requests carry the bearer and session-token headers on the joined URL`() async throws {
        let http = StubHermesHTTP()
        http.respond("GET", "/api/skills", json: "[]")
        let client = makeClient(http)
        _ = try await client.listSkills()
        let request = try #require(http.requests.first)
        #expect(request.url == "http://127.0.0.1:9119/api/skills")
        #expect(request.headers.contains { $0.0 == "Authorization" && $0.1 == "Bearer dash-secret" })
        #expect(request.headers.contains { $0.0 == "X-Hermes-Session-Token" && $0.1 == "dash-secret" })
    }

    @Test
    func `listSkills maps provenance and enabled flags`() async throws {
        let http = StubHermesHTTP()
        http.respond("GET", "/api/skills", json: """
        [{"name":"kb-compile","description":"Compile","enabled":true,"provenance":"agent"},
         {"name":"weather","description":"","enabled":false,"provenance":"hub"},
         {"name":"bundled-one","enabled":true,"provenance":"bundled"},
         {"description":"no name"}]
        """)
        let skills = try await makeClient(http).listSkills()
        #expect(skills.map(\.name) == ["kb-compile", "weather", "bundled-one"])
        #expect(skills[0].source == .custom)
        #expect(skills[1].source == .hub)
        #expect(skills[1].enabled == false)
        #expect(skills[2].source == .builtin)
    }

    @Test
    func `auth probe distinguishes bearer, oauth-only, unauthorized and unreachable`() async {
        let ok = StubHermesHTTP()
        ok.respond("GET", "/api/skills", json: "[]")
        #expect(await makeClient(ok).probeAuthMode(authRequired: false) == .bearer)

        let redirect = StubHermesHTTP()
        redirect.respond("GET", "/api/skills", status: 302, json: "", headers: [("Location", "/login")])
        #expect(await makeClient(redirect).probeAuthMode(authRequired: nil) == .oauthOnly)

        let gated = StubHermesHTTP()
        gated.respond("GET", "/api/skills", status: 401, json: #"{"detail":"Unauthorized"}"#)
        #expect(await makeClient(gated).probeAuthMode(authRequired: true) == .oauthOnly)

        let badToken = StubHermesHTTP()
        badToken.respond("GET", "/api/skills", status: 401, json: #"{"detail":"Unauthorized"}"#)
        #expect(await makeClient(badToken).probeAuthMode(authRequired: false) == .unauthorized)

        let down = StubHermesHTTP()
        down.failure = URLError(.cannotConnectToHost)
        #expect(await makeClient(down).probeAuthMode(authRequired: false) == .unreachable)
    }

    @Test
    func `protected calls surface the auth mode error on a login redirect`() async {
        let http = StubHermesHTTP()
        http.respond("GET", "/api/cron/jobs", status: 303, json: "", headers: [("Location", "/login")])
        await #expect(throws: HermesMirrorTransportError.dashboardAuthModeUnsupported) {
            try await makeClient(http).listJobs()
        }
    }

    @Test
    func `status reads version and auth_required and the default cwd`() async throws {
        let http = StubHermesHTTP()
        http.respond("GET", "/api/status", json: #"{"version":"0.21.0","auth_required":true,"gateway_running":true}"#)
        http.respond("GET", "/api/fs/default-cwd", json: #"{"cwd":"/home/hermes"}"#)
        let status = try await makeClient(http).status()
        #expect(status == HermesDashboardStatus(reachable: true, authRequired: true, version: "0.21.0", defaultCwd: "/home/hermes"))
    }

    @Test
    func `cron jobs parse the dashboard shape and create posts the spec`() async throws {
        let http = StubHermesHTTP()
        http.respond("GET", "/api/cron/jobs", json: """
        [{"id":"8628eaf81dda","name":"Digest","prompt":"p","enabled":true,"state":"scheduled",
          "schedule":{"kind":"cron","expr":"0 9 * * 1-5","display":"0 9 * * 1-5"},"schedule_display":"0 9 * * 1-5",
          "last_run_at":"2026-06-12T09:03:08.536535+00:00","next_run_at":"2026-06-15T09:00:00+00:00"},
         {"id":"paused1","enabled":false}]
        """)
        http.respond("POST", "/api/cron/jobs", json: #"{"id":"new1","name":"luminavault-nightly-compile","schedule":"0 3 * * *","enabled":true}"#)
        let client = makeClient(http)
        let jobs = try await client.listJobs()
        #expect(jobs.count == 2)
        #expect(jobs[0].schedule == "0 9 * * 1-5")
        #expect(jobs[0].paused == false)
        #expect(jobs[0].lastRunAt != nil)
        #expect(jobs[0].nextRunAt != nil)
        #expect(jobs[1].paused == true)

        let created = try await client.createJob(HermesMirrorJobSpec(name: "luminavault-nightly-compile", schedule: "0 3 * * *", prompt: "compile", deliver: "origin", skills: ["kb-compile"]))
        #expect(created.id == "new1")
        let post = try #require(http.requests.first { $0.method == "POST" })
        let body = try #require(post.body)
        #expect(body.contains(#""schedule":"0 3 * * *""#))
        #expect(body.contains(#""skills":["kb-compile"]"#))
        #expect(body.contains(#""deliver":"origin""#))
    }

    @Test
    func `fs list maps entries and rejects traversal before any request`() async throws {
        let http = StubHermesHTTP()
        http.respond("GET", "/api/fs/list", json: #"{"entries":[{"name":"raw","path":"/kb/raw","isDirectory":true},{"name":"a.md","path":"/kb/a.md","isDirectory":false}]}"#)
        let client = makeClient(http)
        let entries = try await client.listFiles(path: "/kb/")
        #expect(entries == [
            HermesMirrorFileEntry(name: "raw", path: "/kb/raw", isDirectory: true),
            HermesMirrorFileEntry(name: "a.md", path: "/kb/a.md", isDirectory: false),
        ])
        #expect(http.requests.first?.url.contains("path=/kb") == true)

        await #expect(throws: HermesMirrorTransportError.invalidPath("/kb/../etc")) {
            try await client.listFiles(path: "/kb/../etc")
        }
        await #expect(throws: HermesMirrorTransportError.invalidPath("relative/path")) {
            try await client.readText(path: "relative/path")
        }
        #expect(http.requests.count == 1)
    }

    @Test
    func `fs read-text maps ENOENT and 413 and binary`() async {
        let http = StubHermesHTTP()
        http.respond("GET", "/api/fs/list", json: #"{"entries":[],"error":"ENOENT"}"#)
        http.respond("GET", "/api/fs/read-text", status: 413, json: #"{"detail":"File too large"}"#)
        let client = makeClient(http)
        await #expect(throws: HermesMirrorTransportError.notFound("/missing")) {
            try await client.listFiles(path: "/missing")
        }
        await #expect(throws: HermesMirrorTransportError.bodyTooLarge(path: "/big.md", limit: HermesDashboardClient.fileBodyCap)) {
            try await client.readText(path: "/big.md")
        }
        let binary = StubHermesHTTP()
        binary.respond("GET", "/api/fs/read-text", json: #"{"binary":true,"text":" "}"#)
        await #expect(throws: HermesMirrorTransportError.invalidResponse("binary:/img.png")) {
            try await makeClient(binary).readText(path: "/img.png")
        }
    }

    @Test
    func `write-text refuses oversized bodies without a request`() async {
        let http = StubHermesHTTP()
        let big = String(repeating: "x", count: HermesDashboardClient.fileBodyCap + 1)
        await #expect(throws: HermesMirrorTransportError.bodyTooLarge(path: "/kb/big.md", limit: HermesDashboardClient.fileBodyCap)) {
            try await makeClient(http).writeText(path: "/kb/big.md", content: big)
        }
        #expect(http.requests.isEmpty)
    }

    @Test
    func `sessions and messages parse the dashboard shapes`() async throws {
        let http = StubHermesHTTP()
        http.respond("GET", "/api/sessions", json: """
        {"sessions":[{"id":"s1","title":"Plan","source":"cli","started_at":1756800000.5,"last_active":1756803600,"message_count":4},
                     {"id":"s2","display_name":"Chat","started_at":"2026-09-01T10:00:00Z","message_count":0}],"total":2,"limit":20,"offset":0}
        """)
        http.respond("GET", "/api/sessions/s1/messages", json: """
        {"session_id":"s1","messages":[{"role":"user","content":"hi","timestamp":1756800001},
                                        {"role":"assistant","content":[{"type":"text","text":"hello"}]},
                                        {"content":"no role"}]}
        """)
        let client = makeClient(http)
        let page = try await client.listSessions(offset: 0, limit: 20)
        #expect(page.total == 2)
        #expect(page.sessions.map(\.id) == ["s1", "s2"])
        #expect(page.sessions[0].title == "Plan")
        #expect(page.sessions[0].messageCount == 4)
        #expect(page.sessions[0].lastActiveAt == Date(timeIntervalSince1970: 1_756_803_600))
        #expect(page.sessions[1].title == "Chat")
        #expect(page.sessions[1].startedAt != nil)
        let listURL = try #require(http.requests.first?.url)
        #expect(listURL.contains("order=recent"))
        #expect(listURL.contains("min_messages=1"))

        let messages = try await client.sessionMessages(id: "s1")
        #expect(messages.map(\.role) == ["user", "assistant"])
        #expect(messages[1].content == "hello")
    }

    @Test
    func `429 backs off using Retry-After then succeeds`() async throws {
        let http = StubHermesHTTP()
        http.respond("GET", "/api/skills", status: 429, json: "{}", headers: [("Retry-After", "0.01")])
        http.respond("GET", "/api/skills", json: #"[{"name":"a"}]"#)
        let skills = try await makeClient(http).listSkills()
        #expect(skills.map(\.name) == ["a"])
        #expect(http.requests.count == 2)
        #expect(HermesDashboardClient.retryDelay(nil, attempt: 2) == .seconds(2))
        #expect(HermesDashboardClient.retryDelay("120", attempt: 1) == .seconds(30))
    }

    @Test
    func `SSRF rejection stops the call before any request`() async {
        let http = StubHermesHTTP()
        let client = HermesDashboardClient(
            baseURL: "http://169.254.169.254/",
            token: "t",
            ssrfGuard: SSRFGuard(allowPrivateRanges: false, requireHTTPS: false, allowTailnetHTTP: false),
            http: http,
            logger: Self.logger
        )
        await #expect(throws: (any Error).self) {
            try await client.listSkills()
        }
        #expect(http.requests.isEmpty)
    }

    @Test
    func `cron bridge keeps its legacy BYO error codes`() {
        #expect(CronBridgeService.byoError(.http(status: 500, path: "/api/cron/jobs"), operation: "http").description.contains("byo_cron_http_500"))
        #expect(CronBridgeService.byoError(.dashboardUnauthorized, operation: "create").description.contains("byo_cron_create_401"))
        #expect(CronBridgeService.byoError(.dashboardAuthModeUnsupported, operation: "http").description.contains("hermes_dashboard_auth_mode_unsupported"))
    }

    @Test
    func `path validation normalises trailing slashes and rejects escapes`() throws {
        #expect(try HermesMirrorPath.validate("/kb/raw/") == "/kb/raw")
        #expect(try HermesMirrorPath.validate("/") == "/")
        #expect(throws: HermesMirrorTransportError.invalidPath("")) { try HermesMirrorPath.validate("") }
        #expect(throws: HermesMirrorTransportError.invalidPath("/a/./b")) { try HermesMirrorPath.validate("/a/./b") }
        let nul = "/a/" + String(UnicodeScalar(0))
        #expect(throws: HermesMirrorTransportError.invalidPath(nul)) { try HermesMirrorPath.validate(nul) }
        #expect(HermesMirrorPath.isInside("/kb/raw/x.md", root: "/kb"))
        #expect(!HermesMirrorPath.isInside("/kbx/raw", root: "/kb"))
    }

    @Test
    func `dates parse ISO with and without offsets and epoch seconds`() {
        #expect(HermesDates.parse("2026-06-12T09:03:08.536535+00:00") != nil)
        #expect(HermesDates.parse("2026-06-15T09:00:00+00:00") != nil)
        #expect(HermesDates.parse("2026-06-15T09:00:00.1") != nil)
        #expect(HermesDates.parse(1_756_800_000.5) == Date(timeIntervalSince1970: 1_756_800_000.5))
        #expect(HermesDates.parse(0) == nil)
        #expect(HermesDates.parse("nope") == nil)
    }
}
