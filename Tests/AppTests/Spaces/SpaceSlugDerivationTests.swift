@testable import App
import Foundation
import Hummingbird
import HummingbirdTesting
import struct LuminaVaultShared.AuthResponse
import struct LuminaVaultShared.SpaceDTO
import Testing

/// `slug` is optional in the contract — `SpaceCreateRequest` requires `name`
/// and nothing else — so a client that sends only a name is sending a valid
/// request and must get a space back.
///
/// It did not. `SpacesController.create` passed `body.slug ?? ""` into
/// `SpaceSlugPolicy.validate`, and the empty string fails the pattern, so
/// every contract-valid request that omitted the slug answered 400
/// "slug must be 2-31 chars…". The integration suite noticed only because
/// four of its cases create a space by name; a real client following the
/// published spec would have hit exactly the same wall.
///
/// The derivation already existed — `ImportService.slugify`, with a comment
/// saying it matches this policy — but it lived on the import path, so the
/// public endpoint never used it.
/// Pure: no database, so it runs in the unit job too.
@Suite
struct SpaceSlugDerivationTests {
    @Test
    func `derives a slug from an ordinary name`() async throws {
        #expect(SpaceSlugPolicy.derive(from: "Capture") == "capture")
        #expect(SpaceSlugPolicy.derive(from: "AliceOnly") == "aliceonly")
        #expect(SpaceSlugPolicy.derive(from: "Reading List") == "reading-list")
    }

    @Test
    func `collapses runs of punctuation into single dashes and trims them`() async throws {
        #expect(SpaceSlugPolicy.derive(from: "  Work / Notes  ") == "work-notes")
        #expect(SpaceSlugPolicy.derive(from: "!!!Ideas!!!") == "ideas")
        #expect(SpaceSlugPolicy.derive(from: "a—b") == "a-b")
    }

    @Test
    func `every derived slug satisfies the policy it is derived for`() async throws {
        // The derivation is only useful if its output always validates. A
        // name made entirely of symbols, or one long enough to truncate, is
        // where a hand-rolled slugifier usually stops satisfying its own rule.
        let names = [
            "Capture", "AliceOnly", "Reading List", "  Work / Notes  ",
            "!!!Ideas!!!", "a—b", "日本語", "🎉🎉", "-leading-dash",
            String(repeating: "long", count: 40),
            String(repeating: "ab-", count: 20),
            "x", "", "   ", "raw", "trash"
        ]
        for name in names {
            let derived = SpaceSlugPolicy.derive(from: name)
            #expect(
                throws: Never.self,
                "derive(from: \(name.debugDescription)) produced \(derived.debugDescription), which its own policy rejects"
            ) {
                try SpaceSlugPolicy.validate(derived)
            }
        }
    }

    @Test
    func `an explicit slug still wins over the name`() async throws {
        #expect(SpaceSlugPolicy.resolve(slug: "chosen", name: "Ignored Name") == "chosen")
        #expect(SpaceSlugPolicy.resolve(slug: "  ", name: "Fallback Name") == "fallback-name")
        #expect(SpaceSlugPolicy.resolve(slug: nil, name: "Fallback Name") == "fallback-name")
    }

    /// Reserved slugs are the one case a derivation cannot simply hand back,
    /// because the policy rejects them by name rather than by shape.
    @Test
    func `a name that derives onto a reserved slug is nudged off it`() async throws {
        for reserved in ["raw", "compiled", "trash", "tmp"] {
            let derived = SpaceSlugPolicy.derive(from: reserved)
            #expect(derived != reserved)
            #expect(throws: Never.self) { try SpaceSlugPolicy.validate(derived) }
        }
    }
}

/// The same promise, through the real endpoint.
@Suite(.serialized, .tags(.integration), .integrationDatabase, .disabled(if: IntegrationTestEnv.skipIntegration))
struct SpaceCreateWithoutSlugTests {
    private static func randomUser() -> (email: String, username: String) {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        return ("slug-\(suffix)@test.luminavault", "slug-\(suffix)")
    }

    private static func registerAndAuth(client: some TestClientProtocol) async throws -> AuthResponse {
        let (email, username) = randomUser()
        return try await client.execute(
            uri: "/v1/auth/register",
            method: .post,
            headers: [.contentType: "application/json"],
            body: ByteBuffer(string: """
            {"email":"\(email)","username":"\(username)","password":"CorrectHorseBatteryStaple1!"}
            """)
        ) { try testJSONDecoder().decode(AuthResponse.self, from: Data(buffer: $0.body)) }
    }

    @Test
    func `creating a space with only a name derives the slug`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.registerAndAuth(client: client).accessToken
            try await client.execute(
                uri: "/v1/spaces",
                method: .post,
                headers: [.authorization: "Bearer \(token)", .contentType: "application/json"],
                body: ByteBuffer(string: #"{"name":"Reading List"}"#)
            ) { response in
                #expect(response.status == .ok || response.status == .created)
                let space = try testJSONDecoder().decode(SpaceDTO.self, from: Data(buffer: response.body))
                #expect(space.name == "Reading List")
                #expect(space.slug == "reading-list")
            }
        }
    }
}
