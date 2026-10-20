@testable import App
import Configuration
import Foundation
import Hummingbird
import HummingbirdTesting
import LuminaVaultShared
import SQLKit
import Testing

/// `/v1/community` end to end against Postgres. Moderation runs on the stub
/// chat provider, which answers every request with `stubReply` — so the
/// model "allows" everything here; rejections and outages are unit-tested in
/// `CommunityModeratorParseTests` and the pre-filter is real.
@Suite(.serialized, .tags(.integration), .integrationDatabase, .disabled(if: IntegrationTestEnv.skipIntegration))
struct CommunityControllerTests {
    private static let stubReply = #"{"allowed": true, "category": "ok"}"#

    private static func reader(enabled: Bool = true, posting: Bool = true) -> ConfigReader {
        dbTestReader(overriding: [
            "community.enabled": cfg(enabled ? "true" : "false"),
            "community.postingEnabled": cfg(posting ? "true" : "false"),
            "llm.provider": cfg("stub"),
            "llm.stub.replyContent": cfg(stubReply),
        ])
    }

    struct Member {
        let token: String
        let email: String
        let username: String
        let userID: UUID
    }

    private static func register(_ client: some TestClientProtocol) async throws -> Member {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        let email = "community-\(suffix)@test.luminavault"
        let username = "community-\(suffix)"
        let auth = try await client.execute(
            uri: "/v1/auth/register", method: .post,
            headers: [.contentType: "application/json"],
            body: ByteBuffer(string: #"{"email":"\#(email)","username":"\#(username)","password":"CorrectHorseBatteryStaple1!"}"#)
        ) { try testJSONDecoder().decode(AuthResponse.self, from: Data(buffer: $0.body)) }
        return Member(token: auth.accessToken, email: email, username: username, userID: auth.userId)
    }

    private static func headers(_ m: Member) -> HTTPFields {
        [.authorization: "Bearer \(m.token)", .contentType: "application/json"]
    }

    @discardableResult
    private static func setUpProfile(_ client: some TestClientProtocol, _ m: Member, handle: String) async throws -> CommunityProfileDTO {
        try await client.execute(
            uri: "/v1/community/profile", method: .put, headers: headers(m),
            body: ByteBuffer(string: #"{"handle":"\#(handle)","displayName":"Member \#(handle)","acceptTerms":true,"termsVersion":1}"#)
        ) { response in
            #expect(response.status == .ok)
            return try testJSONDecoder().decode(CommunityProfileDTO.self, from: Data(buffer: response.body))
        }
    }

    private static func createThread(_ client: some TestClientProtocol, _ m: Member, title: String, body: String) async throws -> CommunityPostDTO {
        try await client.execute(
            uri: "/v1/community/posts", method: .post, headers: headers(m),
            body: ByteBuffer(data: JSONEncoder().encode(CommunityPostCreateRequest(title: title, body: body)))
        ) { response in
            #expect(response.status == .created)
            return try testJSONDecoder().decode(CommunityPostDTO.self, from: Data(buffer: response.body))
        }
    }

    private static func feed(_ client: some TestClientProtocol, _ m: Member) async throws -> (page: CommunityPostPageDTO, raw: String) {
        try await client.execute(uri: "/v1/community/posts?limit=50", method: .get, headers: headers(m)) { response in
            #expect(response.status == .ok)
            let raw = String(buffer: response.body)
            return try (testJSONDecoder().decode(CommunityPostPageDTO.self, from: Data(raw.utf8)), raw)
        }
    }

    private static func handle() -> String {
        "m_" + UUID().uuidString.prefix(8).lowercased()
    }

    // MARK: - Tests

    @Test
    func `the board never reveals an author's email, username or user id`() async throws {
        let app = try await buildApplication(reader: Self.reader())
        try await app.test(.router) { client in
            let a = try await Self.register(client)
            let b = try await Self.register(client)
            try await Self.setUpProfile(client, a, handle: Self.handle())
            let thread = try await Self.createThread(client, a, title: "Paper or app?", body: "I still sketch on paper first.")
            #expect(thread.status == .visible)
            #expect(thread.isOwn)

            let (page, raw) = try await Self.feed(client, b)
            #expect(page.items.contains { $0.id == thread.id })
            #expect(!raw.contains(a.email))
            #expect(!raw.contains(a.username))
            #expect(!raw.lowercased().contains(a.userID.uuidString.lowercased()))
            #expect(page.items.first { $0.id == thread.id }?.isOwn == false)
        }
    }

    @Test
    func `posting needs a profile with accepted terms, and handles are unique`() async throws {
        let app = try await buildApplication(reader: Self.reader())
        try await app.test(.router) { client in
            let a = try await Self.register(client)
            let b = try await Self.register(client)
            try await client.execute(
                uri: "/v1/community/posts", method: .post, headers: Self.headers(a),
                body: ByteBuffer(string: #"{"title":"Hello there","body":"First!"}"#)
            ) { #expect($0.status == .forbidden) }

            try await client.execute(
                uri: "/v1/community/profile", method: .put, headers: Self.headers(a),
                body: ByteBuffer(string: #"{"handle":"\#(Self.handle())","displayName":"A","acceptTerms":false,"termsVersion":1}"#)
            ) { #expect($0.status == .unprocessableContent) }

            let h = Self.handle()
            try await Self.setUpProfile(client, a, handle: h)
            try await client.execute(
                uri: "/v1/community/profile", method: .put, headers: Self.headers(b),
                body: ByteBuffer(string: #"{"handle":"\#(h.uppercased())","displayName":"B","acceptTerms":true,"termsVersion":1}"#)
            ) { #expect($0.status == .conflict || $0.status == .unprocessableContent) }

            let me = try await client.execute(uri: "/v1/community/me", method: .get, headers: Self.headers(a)) {
                try testJSONDecoder().decode(CommunityMeDTO.self, from: Data(buffer: $0.body))
            }
            #expect(me.enabled)
            #expect(me.profile?.handle == h)
            #expect(me.isModerator == false)
        }
    }

    @Test
    func `the pre-filter rejects personal data with a 422`() async throws {
        let app = try await buildApplication(reader: Self.reader())
        try await app.test(.router) { client in
            let a = try await Self.register(client)
            try await Self.setUpProfile(client, a, handle: Self.handle())
            try await client.execute(
                uri: "/v1/community/posts", method: .post, headers: Self.headers(a),
                body: ByteBuffer(string: #"{"title":"Contact","body":"Email her at someone@example.com"}"#)
            ) { #expect($0.status == .unprocessableContent) }
        }
    }

    @Test
    func `a block hides the blocked member for the blocker only`() async throws {
        let app = try await buildApplication(reader: Self.reader())
        try await app.test(.router) { client in
            let a = try await Self.register(client)
            let b = try await Self.register(client)
            let c = try await Self.register(client)
            let aProfile = try await Self.setUpProfile(client, a, handle: Self.handle())
            try await Self.setUpProfile(client, b, handle: Self.handle())
            try await Self.setUpProfile(client, c, handle: Self.handle())
            let thread = try await Self.createThread(client, a, title: "Morning pages", body: "Three pages, every day.")

            try await client.execute(
                uri: "/v1/community/blocks", method: .post, headers: Self.headers(b),
                body: ByteBuffer(string: #"{"profileId":"\#(aProfile.id.uuidString)"}"#)
            ) { #expect($0.status == .noContent) }

            #expect(try await !Self.feed(client, b).page.items.contains { $0.id == thread.id })
            #expect(try await Self.feed(client, c).page.items.contains { $0.id == thread.id })
            try await client.execute(uri: "/v1/community/posts/\(thread.id)", method: .get, headers: Self.headers(b)) {
                #expect($0.status == .notFound)
            }

            try await client.execute(uri: "/v1/community/blocks/\(aProfile.id)", method: .delete, headers: Self.headers(b)) {
                #expect($0.status == .noContent)
            }
            #expect(try await Self.feed(client, b).page.items.contains { $0.id == thread.id })
        }
    }

    @Test
    func `replies count, and three reports hide a post until a moderator restores it`() async throws {
        let app = try await buildApplication(reader: Self.reader())
        try await app.test(.router) { client in
            let author = try await Self.register(client)
            try await Self.setUpProfile(client, author, handle: Self.handle())
            let thread = try await Self.createThread(client, author, title: "Inbox zero?", body: "Does anyone keep it?")

            var reporters: [Member] = []
            for _ in 0 ..< 3 {
                let m = try await Self.register(client)
                try await Self.setUpProfile(client, m, handle: Self.handle())
                reporters.append(m)
            }
            try await client.execute(
                uri: "/v1/community/posts/\(thread.id)/replies", method: .post, headers: Self.headers(reporters[0]),
                body: ByteBuffer(string: #"{"body":"Weekly, not daily."}"#)
            ) { #expect($0.status == .created) }
            let refreshed = try await client.execute(uri: "/v1/community/posts/\(thread.id)", method: .get, headers: Self.headers(author)) {
                try testJSONDecoder().decode(CommunityPostDTO.self, from: Data(buffer: $0.body))
            }
            #expect(refreshed.replyCount == 1)

            // Reporting your own post is refused; a duplicate report is a no-op.
            try await client.execute(
                uri: "/v1/community/posts/\(thread.id)/report", method: .post, headers: Self.headers(author),
                body: ByteBuffer(string: #"{"reason":"spam"}"#)
            ) { #expect($0.status == .badRequest) }
            // reporters[0] twice: the repeat is a no-op, so the post survives
            // until the third distinct reporter.
            for m in [reporters[0], reporters[0], reporters[1], reporters[2]] {
                try await client.execute(
                    uri: "/v1/community/posts/\(thread.id)/report", method: .post, headers: Self.headers(m),
                    body: ByteBuffer(string: #"{"reason":"spam","note":"looks like an ad"}"#)
                ) { #expect($0.status == .accepted) }
            }
            #expect(try await !Self.feed(client, reporters[1]).page.items.contains { $0.id == thread.id })

            // A non-moderator cannot see the queue.
            try await client.execute(uri: "/v1/community/admin/queue", method: .get, headers: Self.headers(author)) {
                #expect($0.status == .forbidden)
            }

            let moderator = try await Self.register(client)
            try await withTestFluent(label: "lv.test.community.admin") { fluent in
                let sql = try #require(fluent.db() as? any SQLDatabase)
                try await sql.raw("UPDATE users SET is_admin = true WHERE id = \(bind: moderator.userID)").run()
            }
            let queue = try await client.execute(uri: "/v1/community/admin/queue?status=hidden", method: .get, headers: Self.headers(moderator)) {
                #expect($0.status == .ok)
                return try testJSONDecoder().decode(CommunityAdminQueueDTO.self, from: Data(buffer: $0.body))
            }
            let item = try #require(queue.items.first { $0.post.id == thread.id })
            #expect(item.openReports == 3)
            #expect(item.reportReasons == [.spam])

            try await client.execute(
                uri: "/v1/community/admin/posts/\(thread.id)/decision", method: .post, headers: Self.headers(moderator),
                body: ByteBuffer(string: #"{"action":"restore"}"#)
            ) { #expect($0.status == .noContent) }
            #expect(try await Self.feed(client, reporters[1]).page.items.contains { $0.id == thread.id })
        }
    }

    @Test
    func `the feed pages with a stable cursor`() async throws {
        let app = try await buildApplication(reader: Self.reader())
        try await app.test(.router) { client in
            let a = try await Self.register(client)
            try await Self.setUpProfile(client, a, handle: Self.handle())
            var created: [UUID] = []
            for i in 0 ..< 5 {
                try await created.append(Self.createThread(client, a, title: "Thread number \(i)", body: "Body \(i)").id)
            }
            var seen: [UUID] = []
            var cursor: String?
            repeat {
                let uri = "/v1/community/posts?limit=2" + (cursor.map { "&cursor=\($0)" } ?? "")
                let page = try await client.execute(uri: uri, method: .get, headers: Self.headers(a)) {
                    try testJSONDecoder().decode(CommunityPostPageDTO.self, from: Data(buffer: $0.body))
                }
                seen += page.items.map(\.id)
                cursor = page.nextCursor
            } while cursor != nil
            #expect(Set(seen).count == seen.count)
            #expect(Set(created).isSubset(of: Set(seen)))
            let mine = seen.filter { created.contains($0) }
            #expect(mine == created.reversed())
        }
    }

    @Test
    func `switches: posting off makes the board read-only, community off hides it`() async throws {
        let readOnly = try await buildApplication(reader: Self.reader(posting: false))
        try await readOnly.test(.router) { client in
            let a = try await Self.register(client)
            try await Self.setUpProfile(client, a, handle: Self.handle())
            try await client.execute(
                uri: "/v1/community/posts", method: .post, headers: Self.headers(a),
                body: ByteBuffer(string: #"{"title":"Hello there","body":"Anyone?"}"#)
            ) { #expect($0.status == .serviceUnavailable) }
            try await client.execute(uri: "/v1/community/posts", method: .get, headers: Self.headers(a)) {
                #expect($0.status == .ok)
            }
        }
        let off = try await buildApplication(reader: Self.reader(enabled: false))
        try await off.test(.router) { client in
            let a = try await Self.register(client)
            let me = try await client.execute(uri: "/v1/community/me", method: .get, headers: Self.headers(a)) {
                try testJSONDecoder().decode(CommunityMeDTO.self, from: Data(buffer: $0.body))
            }
            #expect(!me.enabled)
            try await client.execute(uri: "/v1/community/posts", method: .get, headers: Self.headers(a)) {
                #expect($0.status == .serviceUnavailable)
            }
        }
    }
}
