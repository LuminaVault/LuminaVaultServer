@testable import App
import FluentKit
import Foundation
import Hummingbird
import HummingbirdTesting
import LuminaVaultShared
import Testing

/// A BYOK router save must never store the `openRouter/auto` placeholder.
///
/// `/v1/router` scrubs a managed profile's routes to that placeholder so a
/// managed tenant never learns which model serves them. A client that takes
/// the fetched profile, flips it to BYOK and saves it sends the placeholder
/// back, and it used to be stored verbatim — a BYOK route to a model id no
/// provider serves. The save now substitutes the tenant's saved BYOK chain,
/// and refuses when there is none.
@Suite(.serialized, .tags(.integration), .integrationDatabase, .disabled(if: IntegrationTestEnv.skipIntegration))
struct RouterPlaceholderSaveTests {
    private static let placeholder = RouterModelRouteDTO(
        provider: ManagedLLMDefaults.provider,
        model: ModelDisclosurePolicy.genericModelID
    )

    private static func register(client: some TestClientProtocol) async throws -> AuthResponse {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        return try await client.execute(
            uri: "/v1/auth/register",
            method: .post,
            headers: [.contentType: "application/json"],
            body: ByteBuffer(string: """
            {"email":"placeholder-\(suffix)@test.luminavault","username":"placeholder-\(suffix)","password":"CorrectHorseBatteryStaple1!"}
            """)
        ) { try testJSONDecoder().decode(AuthResponse.self, from: Data(buffer: $0.body)) }
    }

    private static func headers(_ token: String) -> HTTPFields {
        [.authorization: "Bearer \(token)", .contentType: "application/json"]
    }

    private static func defaultProfile(client: some TestClientProtocol, token: String) async throws -> RouterProfileDTO {
        let profiles = try await client.execute(uri: "/v1/router", method: .get, headers: headers(token)) {
            try testJSONDecoder().decode(RouterProfilesResponse.self, from: Data(buffer: $0.body))
        }
        return try #require(profiles.profiles.first { $0.id == profiles.defaultProfileID })
    }

    private static func saveByokPreference(client: some TestClientProtocol, token: String) async throws {
        try await client.execute(
            uri: "/v1/me/preferences/llm",
            method: .put,
            headers: headers(token),
            body: ByteBuffer(string: """
            {"mode":"byok","primaryProvider":"anthropic","primaryModel":"claude-opus-4-7",\
            "fallbackChain":[{"provider":"openai","model":"gpt-4o-mini"}]}
            """)
        ) { #expect($0.status == .ok) }
    }

    /// What a client sends after fetching a scrubbed profile and flipping it.
    private static func byokWrite(
        from profile: RouterProfileDTO,
        name: String? = nil,
        expectedRevision: Int?
    ) -> RouterProfileWriteRequest {
        RouterProfileWriteRequest(
            name: name ?? profile.name,
            mode: .byok,
            objective: profile.objective,
            budget: profile.budget,
            defaultAction: RouterActionDTO(routes: [placeholder]),
            routingPolicy: .balanced,
            expectedRevision: expectedRevision
        )
    }

    private static func storedRoutes(profileID: UUID) async throws -> [RouterModelRouteDTO] {
        try await withTestFluent(label: "lv.test.router-placeholder.read") { fluent in
            let row = try #require(try await RouterProfile.find(profileID, on: fluent.db()))
            return row.document.defaultAction.routes
        }
    }

    @Test
    func `a byok save carrying the placeholder stores the saved byok chain`() async throws {
        let app = try await buildApplication(reader: dbTestReaderWithStubChat())
        try await app.test(.router) { client in
            let auth = try await Self.register(client: client)
            let scrubbed = try await Self.defaultProfile(client: client, token: auth.accessToken)
            #expect(scrubbed.defaultAction.routes == [Self.placeholder], "precondition: a managed profile is scrubbed")

            try await Self.saveByokPreference(client: client, token: auth.accessToken)
            let current = try await Self.defaultProfile(client: client, token: auth.accessToken)

            let body = try testJSONEncoder().encode(Self.byokWrite(from: scrubbed, expectedRevision: current.revision))
            try await client.execute(
                uri: "/v1/router/\(scrubbed.id.uuidString)",
                method: .put,
                headers: Self.headers(auth.accessToken),
                body: ByteBuffer(data: body)
            ) { #expect($0.status == .ok) }

            #expect(try await Self.storedRoutes(profileID: scrubbed.id) == [
                RouterModelRouteDTO(provider: .anthropic, model: "claude-opus-4-7"),
                RouterModelRouteDTO(provider: .openai, model: "gpt-4o-mini"),
            ])
        }
    }

    @Test
    func `a byok save carrying the placeholder with no saved byok preference is refused`() async throws {
        let app = try await buildApplication(reader: dbTestReaderWithStubChat())
        try await app.test(.router) { client in
            let auth = try await Self.register(client: client)
            let scrubbed = try await Self.defaultProfile(client: client, token: auth.accessToken)

            let body = try testJSONEncoder().encode(Self.byokWrite(from: scrubbed, expectedRevision: scrubbed.revision))
            try await client.execute(
                uri: "/v1/router/\(scrubbed.id.uuidString)",
                method: .put,
                headers: Self.headers(auth.accessToken),
                body: ByteBuffer(data: body)
            ) { response in
                #expect(response.status == .badRequest)
                #expect(String(buffer: response.body).contains("router_placeholder_route"))
            }

            #expect(try await Self.storedRoutes(profileID: scrubbed.id) != [Self.placeholder])
        }
    }

    @Test
    func `creating a byok profile from a scrubbed one stores the saved chain`() async throws {
        let app = try await buildApplication(reader: dbTestReaderWithStubChat())
        try await app.test(.router) { client in
            let auth = try await Self.register(client: client)
            try await withTestFluent(label: "lv.test.router-placeholder.pro") { fluent in
                let user = try #require(try await User.find(auth.userId, on: fluent.db()))
                user.tier = "pro"
                try await user.save(on: fluent.db())
            }
            let scrubbed = try await Self.defaultProfile(client: client, token: auth.accessToken)
            try await Self.saveByokPreference(client: client, token: auth.accessToken)

            let body = try testJSONEncoder().encode(Self.byokWrite(from: scrubbed, name: "Copy", expectedRevision: nil))
            let created = try await client.execute(
                uri: "/v1/router",
                method: .post,
                headers: Self.headers(auth.accessToken),
                body: ByteBuffer(data: body)
            ) { response in
                #expect(response.status == .ok)
                return try decodeReporting(RouterProfileDTO.self, from: response)
            }

            #expect(try await Self.storedRoutes(profileID: created.id).first
                == RouterModelRouteDTO(provider: .anthropic, model: "claude-opus-4-7"))
        }
    }

    /// Pins today's behaviour so PR-6b changes it on purpose, not by accident.
    ///
    /// The preferences PUT bumps the default profile's revision. A client that
    /// saves preferences and then the router profile with the revision it read
    /// before gets a 409 — which is what iOS does on managed → BYOK today.
    @Test
    func `a router save with the revision read before a preferences save conflicts`() async throws {
        let app = try await buildApplication(reader: dbTestReaderWithStubChat())
        try await app.test(.router) { client in
            let auth = try await Self.register(client: client)
            let before = try await Self.defaultProfile(client: client, token: auth.accessToken)
            try await Self.saveByokPreference(client: client, token: auth.accessToken)

            let body = try testJSONEncoder().encode(Self.byokWrite(from: before, expectedRevision: before.revision))
            try await client.execute(
                uri: "/v1/router/\(before.id.uuidString)",
                method: .put,
                headers: Self.headers(auth.accessToken),
                body: ByteBuffer(data: body)
            ) { #expect($0.status == .conflict) }
        }
    }
}
