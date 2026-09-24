@testable import App
import Foundation
import Logging
import Testing

/// Muse Chat stage C — Gmail metadata reads and the incremental Google
/// scope, against a stubbed Gmail API. No network.
struct GmailClientTests {
    /// Routes by URL: the list call vs. each message's metadata call.
    actor StubGmail: ConnectorHTTPClient {
        var listBody = #"{"messages":[{"id":"m1","threadId":"t1"},{"id":"m2","threadId":"t2"}],"resultSizeEstimate":2}"#
        var listStatus = 200
        private(set) var urls: [URL] = []
        private(set) var authHeaders: [String] = []

        func setList(status: Int, body: String) {
            listStatus = status
            listBody = body
        }

        func get(url: URL, headers: [String: String]) async throws -> ConnectorHTTPResponse {
            urls.append(url)
            authHeaders.append(headers["Authorization"] ?? "")
            if url.path.hasSuffix("/messages") {
                return ConnectorHTTPResponse(status: listStatus, body: Data(listBody.utf8))
            }
            let id = url.lastPathComponent
            let body = """
            {"id":"\(id)","labelIds":["INBOX","UNREAD"\(id == "m1" ? ",\"IMPORTANT\"" : "")],
             "snippet":"Can you confirm Thursday&#39;s time? Tom &amp; Ana",
             "payload":{"headers":[{"name":"From","value":"Ana <ana@example.com>"},
                                   {"name":"subject","value":"Thursday \(id)"},
                                   {"name":"Date","value":"Tue, 22 Sep 2026 18:04:00 +0100"}]}}
            """
            return ConnectorHTTPResponse(status: 200, body: Data(body.utf8))
        }
    }

    @Test
    func `lists the last day of inbox and reads metadata only`() async throws {
        let stub = StubGmail()
        let messages = try await GmailClient(http: stub).recentInbox(accessToken: "tok", maxResults: 10)
        #expect(messages.count == 2)
        #expect(messages[0] == GmailClient.MessageSummary(
            id: "m1",
            from: "Ana <ana@example.com>",
            subject: "Thursday m1",
            snippet: "Can you confirm Thursday's time? Tom & Ana",
            date: "Tue, 22 Sep 2026 18:04:00 +0100",
            unread: true,
            important: true
        ))
        #expect(messages[1].important == false)

        let urls = await stub.urls.map(\.absoluteString)
        #expect(urls[0].contains("/gmail/v1/users/me/messages?"))
        #expect(urls[0].contains("q=newer_than:1d"))
        #expect(urls[0].contains("labelIds=INBOX"))
        // Bodies are never requested: every get is format=metadata.
        for url in urls.dropFirst() {
            #expect(url.contains("format=metadata"))
            #expect(!url.contains("format=full"))
            #expect(!url.contains("format=raw"))
        }
        #expect(await stub.authHeaders.allSatisfy { $0 == "Bearer tok" })
    }

    @Test
    func `an empty inbox omits messages and is not an error`() async throws {
        let stub = StubGmail()
        await stub.setList(status: 200, body: #"{"resultSizeEstimate":0}"#)
        let messages = try await GmailClient(http: stub).recentInbox(accessToken: "tok")
        #expect(messages.isEmpty)
        #expect(await stub.urls.count == 1)
    }

    @Test
    func `a revoked token surfaces as unauthorized`() async throws {
        let stub = StubGmail()
        await stub.setList(status: 401, body: "{}")
        await #expect(throws: GmailClient.Error.unauthorized) {
            try await GmailClient(http: stub).recentInbox(accessToken: "tok")
        }
    }

    // MARK: - Tool result

    static func service(stub: StubGmail, scope: String?, token: @escaping @Sendable () throws -> String = { "tok" }) -> GmailInboxService {
        GmailInboxService(
            grantedScope: { _ in scope },
            accessToken: { _ in try token() },
            client: GmailClient(http: stub),
            logger: Logger(label: "test.gmail")
        )
    }

    @Test
    func `the tool renders metadata when Gmail is granted`() async throws {
        let stub = StubGmail()
        let out = await Self.service(stub: stub, scope: "openid \(GoogleCalendarOAuthClient.gmailReadonlyScope)")
            .recentInboxJSON(tenantID: UUID(), limit: 5)
        let json = try #require(try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        #expect(json["status"] as? String == "ok")
        #expect(json["count"] as? Int == 2)
        let first = try #require((json["messages"] as? [[String: Any]])?.first)
        #expect(first["subject"] as? String == "Thursday m1")
        #expect(first["body"] == nil)
    }

    @Test
    func `the tool refuses without the Gmail scope and never calls Google`() async {
        let stub = StubGmail()
        let out = await Self.service(stub: stub, scope: GoogleCalendarOAuthClient.scope)
            .recentInboxJSON(tenantID: UUID(), limit: 5)
        #expect(out.contains("\"status\":\"error\""))
        #expect(out.contains("not connected"))
        #expect(await stub.urls.isEmpty)
    }

    @Test
    func `a dead grant asks for a reconnect`() async {
        let stub = StubGmail()
        let out = await Self.service(
            stub: stub,
            scope: GoogleCalendarOAuthClient.gmailReadonlyScope,
            token: { throw CalendarTokenStore.Error.needsReauth }
        ).recentInboxJSON(tenantID: UUID(), limit: 5)
        #expect(out.contains("reconnected"))
    }

    // MARK: - Scope bookkeeping

    @Test
    func `scope checks read the space-separated grant`() {
        let both = "openid https://www.googleapis.com/auth/calendar.events https://www.googleapis.com/auth/gmail.readonly email"
        #expect(GoogleCalendarOAuthClient.grants(both, GoogleCalendarOAuthClient.gmailReadonlyScope))
        #expect(GoogleCalendarOAuthClient.grants(both, GoogleCalendarOAuthClient.calendarEventsScope))
        #expect(!GoogleCalendarOAuthClient.grants(GoogleCalendarOAuthClient.scope, GoogleCalendarOAuthClient.gmailReadonlyScope))
        #expect(!GoogleCalendarOAuthClient.grants(nil, GoogleCalendarOAuthClient.gmailReadonlyScope))
        // A prefix is not a grant.
        #expect(!GoogleCalendarOAuthClient.grants("https://www.googleapis.com/auth/gmail.readonlyX", GoogleCalendarOAuthClient.gmailReadonlyScope))

        let calendarOnly = GoogleCalendarOAuthService.withoutGmail(both)
        #expect(!GoogleCalendarOAuthClient.grants(calendarOnly, GoogleCalendarOAuthClient.gmailReadonlyScope))
        #expect(GoogleCalendarOAuthClient.grants(calendarOnly, GoogleCalendarOAuthClient.calendarEventsScope))
        let gmailOnly = GoogleCalendarOAuthService.withoutCalendar(both)
        #expect(GoogleCalendarOAuthClient.grants(gmailOnly, GoogleCalendarOAuthClient.gmailReadonlyScope))
        #expect(!GoogleCalendarOAuthClient.grants(gmailOnly, GoogleCalendarOAuthClient.calendarEventsScope))
    }

    @Test
    func `a token response without scope keeps the old grant and adds the new one`() {
        let merged = GoogleCalendarOAuthService.effectiveScope(
            returned: nil,
            existing: GoogleCalendarOAuthClient.scope,
            requested: GoogleCalendarOAuthClient.gmailConnectScope
        )
        #expect(GoogleCalendarOAuthClient.grants(merged, GoogleCalendarOAuthClient.calendarEventsScope))
        #expect(GoogleCalendarOAuthClient.grants(merged, GoogleCalendarOAuthClient.gmailReadonlyScope))
        #expect(merged.split(separator: " ").filter { $0 == "openid" }.count == 1)
        #expect(GoogleCalendarOAuthService.effectiveScope(returned: "a b", existing: "c", requested: "d") == "a b")
    }

    @Test
    func `Connect Gmail asks only for gmail.readonly and keeps earlier grants`() throws {
        let client = GoogleCalendarOAuthClient(
            clientID: "client-id",
            clientSecret: "not-a-secret",
            redirectURI: "https://api.example/v1/calendar/oauth/callback",
            logger: Logger(label: "test.oauth")
        )
        let url = try #require(URLComponents(string: client.authorizeURL(state: "s", scope: GoogleCalendarOAuthClient.gmailConnectScope)))
        let items = Dictionary(uniqueKeysWithValues: (url.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(items["scope"] == "https://www.googleapis.com/auth/gmail.readonly openid email")
        #expect(items["include_granted_scopes"] == "true")
        #expect(items["access_type"] == "offline")
        #expect(items["redirect_uri"] == "https://api.example/v1/calendar/oauth/callback")
        // The calendar flow is unchanged.
        let calendar = try #require(URLComponents(string: client.authorizeURL(state: "s")))
        #expect(calendar.queryItems?.first { $0.name == "scope" }?.value == GoogleCalendarOAuthClient.scope)
    }

    @Test
    func `each flow hands back to its own app deep link`() {
        #expect(GoogleCalendarOAuthService.requestedScope(.gmail) == GoogleCalendarOAuthClient.gmailConnectScope)
        #expect(GoogleCalendarOAuthService.requestedScope(.calendar) == GoogleCalendarOAuthClient.scope)
        #expect(GoogleCalendarOAuthService.redirect(base: GoogleCalendarOAuthService.gmailAppCallbackBase, status: "ok", reason: nil)
            == "luminavault://oauth/google-gmail?status=ok")
    }
}
