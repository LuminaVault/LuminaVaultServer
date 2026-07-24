@testable import App
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import LuminaVaultShared
import SQLKit
import Testing

@Suite(.serialized, .tags(.integration), .integrationDatabase, .disabled(if: IntegrationTestEnv.skipIntegration))
struct AnalyticsEndpointsTests {
    private struct MissingSQLDatabase: Error {}

    private static func register(client: some TestClientProtocol) async throws -> AuthResponse {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        let body = ByteBuffer(string: """
        {"email":"analytics-\(suffix)@test.luminavault","username":"analytics-\(suffix)","password":"CorrectHorseBatteryStaple1!"}
        """)
        return try await client.execute(
            uri: "/v1/auth/register",
            method: .post,
            headers: [.contentType: "application/json"],
            body: body
        ) { response in
            try testJSONDecoder().decode(AuthResponse.self, from: Data(buffer: response.body))
        }
    }

    private static func insertRouterExecution(
        tenantID: UUID,
        provider: String,
        model: String,
        tokensIn: Int = 100,
        tokensOut: Int = 50,
        costMicros: Int = 1234,
        latencyMs: Int = 250
    ) async throws {
        try await withTestFluent(label: "lv.test.analytics.router-execution") { fluent in
            guard let sql = fluent.db() as? any SQLDatabase else {
                throw MissingSQLDatabase()
            }
            try await sql.raw("""
            INSERT INTO router_executions
                (id, tenant_id, actor_user_id, vault_id, surface, task_type, strategy, status,
                 selected_provider, selected_model, tokens_in, tokens_out,
                 estimated_cost_usd_micros, latency_ms, usage_estimated, fallback_count, occurred_at)
            VALUES
                (\(bind: UUID()), \(bind: tenantID), \(bind: tenantID), \(bind: tenantID),
                 'chat', 'general', 'single', 'ok', \(bind: provider), \(bind: model),
                 \(bind: tokensIn), \(bind: tokensOut), \(bind: costMicros), \(bind: latencyMs),
                 false, 0, NOW())
            """).run()
        }
    }

    @Test("Analytics endpoints require authentication")
    func requiresAuthentication() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            for uri in ["/v1/analytics/overview", "/v1/analytics/models", "/v1/analytics/team",
                        "/v1/analytics/retrieval-health"]
            {
                try await client.execute(uri: uri, method: .get) { response in
                    #expect(response.status == .unauthorized)
                }
            }
        }
    }

    @Test("Fresh retrieval health returns empty-window defaults")
    func freshRetrievalHealth() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let auth = try await Self.register(client: client)
            try await client.execute(
                uri: "/v1/analytics/retrieval-health",
                method: .get,
                headers: [.authorization: "Bearer \(auth.accessToken)"]
            ) { response in
                #expect(response.status == .ok)
                let health = try testJSONDecoder().decode(
                    RetrievalHealthResponse.self,
                    from: Data(buffer: response.body)
                )
                #expect(health.eventsCount == 0)
                #expect(health.hitRate == nil)
                #expect(health.leakCount == 0)
                #expect(health.trend == .steady)
            }
        }
    }

    @Test("Fresh personal analytics return the complete contract")
    func freshOverview() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let auth = try await Self.register(client: client)
            try await client.execute(
                uri: "/v1/analytics/overview?range=7d&scope=personal",
                method: .get,
                headers: [.authorization: "Bearer \(auth.accessToken)"]
            ) { response in
                #expect(response.status == .ok)
                let body = try testJSONDecoder().decode(
                    AnalyticsOverviewResponse.self,
                    from: Data(buffer: response.body)
                )
                #expect(body.scope == .personal)
                #expect(body.range == .week)
                #expect(body.vaultId == auth.userId)
                #expect(body.daily.count == 7)
                #expect(body.memoryHealth.totalMemories == 0)
            }
        }
    }

    @Test("Managed model analytics hide upstream provider and model")
    func managedModelsHideUpstreamIdentity() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let auth = try await Self.register(client: client)
            try await Self.insertRouterExecution(
                tenantID: auth.userId,
                provider: "openrouter",
                model: "anthropic/claude-opus-4-1",
                tokensIn: 200,
                tokensOut: 75,
                costMicros: 5000
            )
            try await Self.insertRouterExecution(
                tenantID: auth.userId,
                provider: "anthropic",
                model: "claude-sonnet-4-6",
                tokensIn: 25,
                tokensOut: 10,
                costMicros: 1000
            )

            try await client.execute(
                uri: "/v1/analytics/models?scope=personal",
                method: .get,
                headers: [.authorization: "Bearer \(auth.accessToken)"]
            ) { response in
                #expect(response.status == .ok)
                let body = try testJSONDecoder().decode(
                    ModelEffectivenessResponse.self,
                    from: Data(buffer: response.body)
                )
                #expect(body.models.count == 1)
                let model = try #require(body.models.first)
                #expect(model.provider == ModelDisclosurePolicy.genericProviderName)
                #expect(model.model == ModelDisclosurePolicy.genericModelID)
                #expect(model.requests == 2)
                #expect(model.tokens == 310)
                #expect(model.estimatedCostUsdMicros == 6000)
            }
        }
    }

    @Test("BYOK model analytics preserve user-selected provider and model")
    func byokModelsPreserveUpstreamIdentity() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let auth = try await Self.register(client: client)
            try await client.execute(
                uri: "/v1/me/preferences/llm",
                method: .put,
                headers: [
                    .authorization: "Bearer \(auth.accessToken)",
                    .contentType: "application/json",
                ],
                body: ByteBuffer(string: """
                {"mode":"byok","primaryProvider":"anthropic","primaryModel":"claude-opus-4-1","fallbackChain":[]}
                """)
            ) { response in
                #expect(response.status == .ok)
            }
            try await Self.insertRouterExecution(
                tenantID: auth.userId,
                provider: "anthropic",
                model: "claude-opus-4-1"
            )

            try await client.execute(
                uri: "/v1/analytics/models?scope=personal",
                method: .get,
                headers: [.authorization: "Bearer \(auth.accessToken)"]
            ) { response in
                #expect(response.status == .ok)
                let body = try testJSONDecoder().decode(
                    ModelEffectivenessResponse.self,
                    from: Data(buffer: response.body)
                )
                let model = try #require(body.models.first)
                #expect(model.provider == "anthropic")
                #expect(model.model == "claude-opus-4-1")
            }
        }
    }

    @Test("Analytics reject cross-vault reads")
    func rejectsCrossVaultRead() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let first = try await Self.register(client: client)
            let second = try await Self.register(client: client)
            try await client.execute(
                uri: "/v1/analytics/overview",
                method: .get,
                headers: [
                    .authorization: "Bearer \(first.accessToken)",
                    VaultAccessService.vaultHeader: second.userId.uuidString,
                ]
            ) { response in
                #expect(response.status == .forbidden)
            }
        }
    }

    @Test("Client event validation is content-free and idempotency-safe")
    func validatesClientEvents() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let auth = try await Self.register(client: client)
            let headers: HTTPFields = [
                .authorization: "Bearer \(auth.accessToken)",
                .contentType: "application/json",
            ]
            try await client.execute(
                uri: "/v1/analytics/events",
                method: .post,
                headers: headers,
                body: ByteBuffer(string: #"{"name":"analytics_dashboard_viewed","source":"web","range":"7d","idempotencyKey":"safe-key-1"}"#)
            ) { response in
                #expect(response.status == .ok)
            }
            try await client.execute(
                uri: "/v1/analytics/events",
                method: .post,
                headers: headers,
                body: ByteBuffer(string: #"{"name":"analytics_dashboard_viewed","source":"web","idempotencyKey":"unsafe key"}"#)
            ) { response in
                #expect(response.status == .badRequest)
            }
        }
    }

    @Test("Model feedback accepts only content-free model identities")
    func validatesModelFeedback() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let auth = try await Self.register(client: client)
            let headers: HTTPFields = [
                .authorization: "Bearer \(auth.accessToken)",
                .contentType: "application/json",
            ]
            try await client.execute(
                uri: "/v1/analytics/model-feedback",
                method: .post,
                headers: headers,
                body: ByteBuffer(string: #"{"provider":"openai","model":"gpt-test","rating":"positive","idempotencyKey":"feedback-1"}"#)
            ) { response in
                #expect(response.status == .ok)
            }
            try await client.execute(
                uri: "/v1/analytics/model-feedback",
                method: .post,
                headers: headers,
                body: ByteBuffer(string: #"{"provider":"openai","model":"prompt content is forbidden","rating":"negative"}"#)
            ) { response in
                #expect(response.status == .badRequest)
            }
        }
    }

    @Test("Memory health queues validate their filter")
    func validatesHealthFilter() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let auth = try await Self.register(client: client)
            try await client.execute(
                uri: "/v1/memory?healthFilter=not-real",
                method: .get,
                headers: [.authorization: "Bearer \(auth.accessToken)"]
            ) { response in
                #expect(response.status == .badRequest)
            }
        }
    }
}
