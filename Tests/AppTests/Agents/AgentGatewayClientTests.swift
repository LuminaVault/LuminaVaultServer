@testable import App
import Foundation
import Logging
import Testing

/// The Agents page's reads against a user's own Hermes gateway.
struct AgentGatewayClientTests {
    private static func client(_ http: StubHermesHTTP) -> AgentGatewayClient {
        AgentGatewayClient(
            baseURL: URL(string: "https://hermes.example.com")!,
            authHeader: "Bearer sk-test",
            http: http,
            logger: Logger(label: "test.agents")
        )
    }

    private static let twoProfiles = """
    {"object":"list","has_more":false,"errors":[],"data":[
      {"id":"tg_1","source":"telegram","title":"Groceries","started_at":1790000000.5,
       "last_active":1790000100.0,"message_count":4,"profile":"mac-mcp","is_active":true,
       "estimated_cost_usd":0.002},
      {"id":"cron_1","source":"cron","title":"","preview":"daily brief","started_at":1789990000.0,
       "profile":"default","is_active":false}
    ]}
    """

    @Test
    func `sessions from every profile keep their profile and source`() async throws {
        let http = StubHermesHTTP()
        http.respond("GET", "/api/profiles/sessions", json: Self.twoProfiles)

        let page = try await Self.client(http).sessions(instanceID: "byo", profile: nil, source: nil, limit: 50)

        #expect(page.profileAware)
        #expect(page.sessions.map(\.id) == ["tg_1", "cron_1"])
        let telegram = try #require(page.sessions.first)
        #expect(telegram.profile == "mac-mcp")
        #expect(telegram.source == "telegram")
        #expect(telegram.isActive)
        #expect(telegram.messageCount == 4)
        #expect(telegram.costUSD == 0.002)
        #expect(telegram.startedAt == Date(timeIntervalSince1970: 1_790_000_000.5))
        // An empty title falls back to the preview.
        #expect(page.sessions.last?.title == "daily brief")
        // The gateway key goes on every call.
        #expect(http.requests.first?.headers.contains { $0.0 == "Authorization" && $0.1 == "Bearer sk-test" } == true)
    }

    @Test
    func `an older Hermes falls back to its own profile's sessions`() async throws {
        let http = StubHermesHTTP()
        // No /api/profiles/sessions route → the stub's plain 404.
        http.respond("GET", "/api/sessions", json: #"{"data":[{"id":"s1","source":"api_server","started_at":1}]}"#)

        let page = try await Self.client(http).sessions(instanceID: "byo", profile: nil, source: nil, limit: 50)

        #expect(!page.profileAware)
        #expect(page.sessions.map(\.id) == ["s1"])
        #expect(page.sessions.first?.profile == nil)
    }

    @Test
    func `an unknown profile is a real 404, not an older Hermes`() async throws {
        let http = StubHermesHTTP()
        http.respond(
            "GET", "/api/profiles/sessions", status: 404,
            json: #"{"error":{"message":"Profile 'x' does not exist.","code":"profile_not_found"}}"#
        )

        await #expect(throws: AgentGatewayClient.Failure.http(404)) {
            try await Self.client(http).sessions(instanceID: "byo", profile: "x", source: nil, limit: 50)
        }
        #expect(!http.requests.contains { $0.url.contains("/api/sessions") })
    }

    @Test
    func `messages come from the named profile, tool calls as JSON text`() async throws {
        let http = StubHermesHTTP()
        http.respond("GET", "/api/profiles/mac-mcp/sessions/tg_1/messages", json: """
        {"session_id":"tg_1","data":[
          {"role":"user","content":"add milk","timestamp":1790000000.0},
          {"role":"assistant","content":null,"tool_calls":[{"id":"c1","function":{"name":"reminder_create"}}]},
          {"role":"tool","content":"{\\"status\\":\\"ok\\"}","tool_name":"reminder_create"}
        ]}
        """)

        let (id, messages) = try await Self.client(http).messages(profile: "mac-mcp", sessionID: "tg_1")

        #expect(id == "tg_1")
        #expect(messages.map(\.role) == ["user", "assistant", "tool"])
        #expect(messages[1].toolCalls?.contains("reminder_create") == true)
        #expect(messages[2].toolName == "reminder_create")
    }

    @Test
    func `ids that could leave the route are refused before any request`() async {
        let http = StubHermesHTTP()
        for bad in ["../secrets", "a/b", "..", "", "x\n"] {
            await #expect(throws: AgentGatewayClient.Failure.invalidID) {
                try await Self.client(http).messages(profile: nil, sessionID: bad)
            }
            await #expect(throws: AgentGatewayClient.Failure.invalidID) {
                try await Self.client(http).messages(profile: bad, sessionID: "ok")
            }
        }
        #expect(http.requests.isEmpty)
    }

    @Test
    func `instance reports profiles and an older Hermes says so`() async throws {
        let http = StubHermesHTTP()
        http.respond("GET", "/api/instance", json: #"{"hostname":"hermes-vps-2","version":"0.18.2","profiles":["default","mac-mcp"]}"#)
        let info = try await Self.client(http).instance()
        #expect(info == .init(hostname: "hermes-vps-2", version: "0.18.2", profiles: ["default", "mac-mcp"]))

        await #expect(throws: AgentGatewayClient.Failure.notSupported) {
            try await Self.client(StubHermesHTTP()).instance()
        }
    }

    @Test
    func `only connected platforms are listed`() async {
        let http = StubHermesHTTP()
        http.respond("GET", "/health/detailed", json: """
        {"platforms":{"telegram":{"state":"connected"},"discord":{"state":"error"},"whatsapp":{}}}
        """)
        #expect(await Self.client(http).connectedPlatforms() == ["telegram", "whatsapp"])
    }

    @Test
    func `an unreachable gateway is reported as such`() async {
        let http = StubHermesHTTP()
        struct ConnectionRefused: Error {}
        http.failure = ConnectionRefused()
        await #expect(throws: AgentGatewayClient.Failure.unreachable) {
            try await Self.client(http).instance()
        }
    }
}
