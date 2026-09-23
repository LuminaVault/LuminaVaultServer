@testable import App
import Foundation
import Hummingbird
import HummingbirdTesting
import LuminaVaultShared
import Testing

/// BYOK tier parity and fail-closed missing-key behaviour.
@Suite(.serialized, .tags(.integration), .integrationDatabase, .disabled(if: IntegrationTestEnv.skipIntegration))
struct BYOKConsistencyTests {
    private static func randomUser() -> (email: String, username: String) {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        return ("byok-\(suffix)@test.luminavault", "byok-\(suffix)")
    }

    private static func register(client: some TestClientProtocol) async throws -> String {
        let (email, username) = randomUser()
        let resp = try await client.execute(
            uri: "/v1/auth/register",
            method: .post,
            headers: [.contentType: "application/json"],
            body: ByteBuffer(string: """
            {"email":"\(email)","username":"\(username)","password":"CorrectHorseBatteryStaple1!"}
            """)
        ) { try testJSONDecoder().decode(AuthResponse.self, from: Data(buffer: $0.body)) }
        return resp.accessToken
    }

    private static func decodeProfiles(_ buffer: ByteBuffer) throws -> RouterProfilesResponse {
        try testJSONDecoder().decode(RouterProfilesResponse.self, from: Data(buffer: buffer))
    }

    private static func writeRequest(from profile: RouterProfileDTO, mode: LLMBrainMode) -> RouterProfileWriteRequest {
        RouterProfileWriteRequest(
            name: profile.name,
            mode: mode,
            objective: profile.objective,
            budget: profile.budget,
            allowedProviders: profile.allowedProviders,
            blockedProviders: profile.blockedProviders,
            defaultAction: profile.defaultAction,
            rules: profile.rules,
            routingPolicy: profile.routingPolicy,
            expectedRevision: profile.revision
        )
    }

    @Test
    func `trial user can set default router profile to byok`() async throws {
        let app = try await buildApplication(reader: dbTestReaderWithStubChat())
        try await app.test(.router) { client in
            let token = try await Self.register(client: client)
            let profiles = try await client.execute(
                uri: "/v1/router",
                method: .get,
                headers: [.authorization: "Bearer \(token)"]
            ) { try Self.decodeProfiles($0.body) }
            let active = try #require(profiles.profiles.first { $0.id == profiles.defaultProfileID })
            // This test is about tier: a trial account is allowed onto BYOK.
            // Two things it used to carry along by copying the fetched profile
            // wholesale are kept out, because each is its own rule and neither
            // is what this case is about:
            //
            //  - the `autoSmart` policy. BYOK + Auto needs the tenant's own
            //    OpenRouter credential (cc87d10, AUTO_REQUIRES_OPENROUTER), and
            //    a fresh signup has none.
            //  - the default route. `/v1/router` scrubs a managed profile's
            //    routes to the `openRouter/auto` placeholder, so the fetched
            //    profile does not carry the real route to send back.
            let body = RouterProfileWriteRequest(
                name: active.name,
                mode: .byok,
                objective: active.objective,
                budget: active.budget,
                allowedProviders: active.allowedProviders,
                blockedProviders: active.blockedProviders,
                defaultAction: RouterActionDTO(routes: [
                    RouterModelRouteDTO(provider: .openRouter, model: ManagedLLMDefaults.model),
                ]),
                rules: active.rules,
                routingPolicy: .balanced,
                expectedRevision: active.revision
            )
            let encoded = try testJSONEncoder().encode(body)
            try await client.execute(
                uri: "/v1/router/\(active.id.uuidString)",
                method: .put,
                headers: [.authorization: "Bearer \(token)", .contentType: "application/json"],
                body: ByteBuffer(data: encoded)
            ) { response in
                #expect(response.status == .ok)
                let updated = try decodeReporting(RouterProfileDTO.self, from: response)
                #expect(updated.mode == .byok)
            }
        }
    }

    /// Selecting BYOK with no key stored is no longer a 403 dead end.
    ///
    /// `FreeLanePolicy` rule 2b diverts the request to the free lane on every
    /// entitled tier instead. In this test environment no platform provider key
    /// is registered, so the lane has no funded leg and reports that it is
    /// unavailable — a 503 with ways out, not a 403 telling the user to go add
    /// a key, and not a 429 claiming an allowance they never used. With
    /// `LLM_PROVIDER_OPEN_ROUTER_API_KEY` present the same request answers
    /// normally off the free lane; see `FreeLaneRoutingTests`.
    @Test
    func `byok chat without provider keys reaches the free lane, not a 403`() async throws {
        let app = try await buildApplication(reader: dbTestReaderWithStubChat())
        try await app.test(.router) { client in
            let token = try await Self.register(client: client)
            try await client.execute(
                uri: "/v1/me/preferences/llm",
                method: .put,
                headers: [.authorization: "Bearer \(token)", .contentType: "application/json"],
                body: ByteBuffer(string: """
                {"mode":"byok","primaryProvider":"anthropic","primaryModel":"claude-opus-4-7","fallbackChain":[]}
                """)
            ) { response in
                #expect(response.status == .ok)
            }

            try await client.execute(
                uri: "/v1/llm/chat",
                method: .post,
                headers: [.authorization: "Bearer \(token)", .contentType: "application/json"],
                body: ByteBuffer(string: """
                {"messages":[{"role":"user","content":"Hello"}]}
                """)
            ) { response in
                // No lane provider is loaded in tests, so the lane cannot
                // serve this turn. That is unavailability — a 503 with no
                // reset timer — not "you've used today's free messages".
                #expect(response.status == .serviceUnavailable)
                #expect(response.headers[.retryAfter] == nil)
                let json = try #require(
                    JSONSerialization.jsonObject(with: Data(buffer: response.body)) as? [String: Any]
                )
                let error = try #require(json["error"] as? [String: Any])
                // The dead end the lane removed.
                #expect(error["code"] as? String != "byok_keys_required")
                #expect(error["code"] as? String == "free_lane_unavailable")
                #expect(error["retryAfterSeconds"] == nil)
                #expect((error["message"] as? String)?.isEmpty == false)
                let cta = try #require(error["cta"] as? [String])
                #expect(cta.contains("add_key"))
                // A fresh signup is a trial account: entitled to managed, so it
                // is offered managed rather than an upgrade.
                #expect(cta.contains("switch_to_managed"))
                #expect(!cta.contains("upgrade"))
            }
        }
    }
}
