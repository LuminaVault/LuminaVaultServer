@testable import App
import FluentKit
import Foundation
import Hummingbird
import HummingbirdTesting
import LuminaVaultShared
import SQLKit
import Testing

@Suite(.serialized, .tags(.integration), .integrationDatabase, .disabled(if: IntegrationTestEnv.skipIntegration))
struct UsageMetricsTests {
    private static let password = "CorrectHorseBatteryStaple1!"

    private struct UsageResponse: Decodable {
        let tier: String
        let storageBytes: Int64
        let tokensIn: Int64
        let tokensOut: Int64
        let tokensTotal: Int64
        let ttsCharacters: Int64
        let compileRuns: Int64
        let compileFiles: Int64
    }

    private static func randomUser(prefix: String) -> (email: String, username: String) {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        return ("\(prefix)-\(suffix)@test.luminavault", "\(prefix)-\(suffix)")
    }

    private static func register(client: some TestClientProtocol, prefix: String = "usage") async throws -> AuthResponse {
        let user = randomUser(prefix: prefix)
        return try await client.execute(
            uri: "/v1/auth/register",
            method: .post,
            headers: [.contentType: "application/json"],
            body: ByteBuffer(string: #"{"email":"\#(user.email)","username":"\#(user.username)","password":"\#(password)"}"#)
        ) { response in
            #expect(response.status == .ok)
            return try testJSONDecoder().decode(AuthResponse.self, from: Data(buffer: response.body))
        }
    }

    @discardableResult
    private static func upload(
        client: some TestClientProtocol,
        token: String,
        path: String,
        body: String
    ) async throws -> VaultUploadResponse {
        try await client.execute(
            uri: "/v1/vault/files?path=\(path)",
            method: .post,
            headers: [.authorization: "Bearer \(token)", .contentType: "text/markdown"],
            body: ByteBuffer(string: body)
        ) { response in
            #expect(response.status == .ok || response.status == .created)
            return try testJSONDecoder().decode(VaultUploadResponse.self, from: Data(buffer: response.body))
        }
    }

    private static func addUsageMeterRows(tenantID: UUID) async throws {
        try await withTestFluent(label: "test.usage-metrics.seed") { fluent in
            guard let sql = fluent.db() as? any SQLDatabase else {
                Issue.record("SQL driver required")
                return
            }
            try await sql.raw("""
            INSERT INTO usage_meter (tenant_id, day, model, mtok_in, mtok_out, chars_out)
            VALUES
                (\(bind: tenantID), CURRENT_DATE, 'openai/gpt-5', 120, 80, 0),
                (\(bind: tenantID), CURRENT_DATE, 'tts/tts-1', 0, 0, 350),
                (\(bind: tenantID), CURRENT_DATE - INTERVAL '40 days', 'old/model', 999, 999, 999)
            ON CONFLICT (tenant_id, day, model) DO UPDATE
                SET mtok_in = EXCLUDED.mtok_in,
                    mtok_out = EXCLUDED.mtok_out,
                    chars_out = EXCLUDED.chars_out
            """).run()
        }
    }

    private static func addUsageEventRows(tenantID: UUID) async throws {
        try await withTestFluent(label: "test.usage-events.seed") { fluent in
            guard let sql = fluent.db() as? any SQLDatabase else {
                Issue.record("SQL driver required")
                return
            }
            try await sql.raw("""
            INSERT INTO usage_events (tenant_id, occurred_at, metric, amount, source, idempotency_key, metadata)
            VALUES
                (\(bind: tenantID), CURRENT_TIMESTAMP, 'memory_compile_run', 1, 'test', \(bind: "test-run-\(tenantID.uuidString)"), '{}'::jsonb),
                (\(bind: tenantID), CURRENT_TIMESTAMP, 'memory_compile_file', 5, 'test', \(bind: "test-files-\(tenantID.uuidString)"), '{}'::jsonb),
                (\(bind: tenantID), CURRENT_TIMESTAMP - INTERVAL '40 days', 'memory_compile_run', 99, 'test', \(bind: "old-run-\(tenantID.uuidString)"), '{}'::jsonb)
            ON CONFLICT (tenant_id, idempotency_key) WHERE idempotency_key IS NOT NULL
            DO UPDATE SET amount = EXCLUDED.amount
            """).run()
        }
    }

    @Test
    func `me usage reports current month storage and token totals`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let auth = try await Self.register(client: client)
            let uploaded = try await Self.upload(
                client: client,
                token: auth.accessToken,
                path: "usage.md",
                body: "usage metrics body"
            )
            try await Self.addUsageMeterRows(tenantID: auth.userId)

            try await client.execute(
                uri: "/v1/auth/me/usage",
                method: .get,
                headers: [.authorization: "Bearer \(auth.accessToken)"]
            ) { response in
                #expect(response.status == .ok)
                let usage = try testJSONDecoder().decode(UsageResponse.self, from: Data(buffer: response.body))
                #expect(usage.tier == "trial")
                #expect(usage.storageBytes == Int64(uploaded.size))
                #expect(usage.tokensIn == 120)
                #expect(usage.tokensOut == 80)
                #expect(usage.tokensTotal == 200)
                #expect(usage.ttsCharacters == 350)
                #expect(usage.compileRuns == 0)
                #expect(usage.compileFiles == 0)
            }
        }
    }

    @Test
    func `me usage reports current month compile events`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let auth = try await Self.register(client: client, prefix: "compile-usage")
            try await Self.addUsageEventRows(tenantID: auth.userId)

            try await client.execute(
                uri: "/v1/auth/me/usage",
                method: .get,
                headers: [.authorization: "Bearer \(auth.accessToken)"]
            ) { response in
                #expect(response.status == .ok)
                let usage = try testJSONDecoder().decode(UsageResponse.self, from: Data(buffer: response.body))
                #expect(usage.compileRuns == 1)
                #expect(usage.compileFiles == 5)
            }
        }
    }
}
