@testable import App
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import LuminaVaultShared
import Testing

/// Hermes Mirror Phase 2 slice 6 — the optional inbound push.
///
/// The push only shortens the wait for a collect the poller would do anyway,
/// so these tests care about two things: that nothing unsigned gets in, and
/// that a push and a poll over the same runs agree.
@Suite(.serialized, .tags(.integration), .integrationDatabase, .disabled(if: IntegrationTestEnv.skipIntegration))
struct HermesMirrorWebhookControllerTests {
    private static let hermesRoot = URL(fileURLWithPath: "/tmp/luminavault-test-hermes", isDirectory: true)

    private static func register(client: some TestClientProtocol) async throws -> HTTPFields {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        let body = ByteBuffer(string: """
        {"email":"hook-\(suffix)@test.luminavault","username":"hook-\(suffix)","password":"CorrectHorseBatteryStaple1!"}
        """)
        let response = try await client.execute(uri: "/v1/auth/register", method: .post, headers: [.contentType: "application/json"], body: body) {
            try testJSONDecoder().decode(AuthResponse.self, from: Data(buffer: $0.body))
        }
        return [.authorization: "Bearer \(response.accessToken)", .contentType: "application/json"]
    }

    private static func decode<T: Decodable>(_: T.Type, _ buffer: ByteBuffer) throws -> T {
        try testJSONDecoder().decode(T.self, from: Data(buffer: buffer))
    }

    /// Mints the credential for a fresh tenant.
    private static func rotate(_ client: some TestClientProtocol, _ auth: HTTPFields) async throws -> HermesMirrorWebhookDTO {
        try await client.execute(uri: "/v1/hermes/mirror/webhook", method: .post, headers: auth) { response in
            #expect(response.status == .ok)
            return try decode(HermesMirrorWebhookDTO.self, response.body)
        }
    }

    /// Creates a job on the shared test Hermes and files one finished run's
    /// output the way `save_job_output` does. Unique per call, so suites
    /// running side by side never share a `cron/output/<job>` directory.
    private static func seedJobWithOutput(_ client: some TestClientProtocol, _ auth: HTTPFields) async throws -> (id: String, cleanup: () -> Void) {
        let name = "hook-job-\(UUID().uuidString.prefix(6).lowercased())"
        let create = ByteBuffer(string: #"{"name":"\#(name)","schedule":"0 9 * * *","prompt":"Write the brief"}"#)
        let jobID = try await client.execute(uri: "/v1/hermes/mirror/jobs", method: .post, headers: auth, body: create) { response in
            #expect(response.status == .ok)
            return try decode(HermesMirroredJobDTO.self, response.body).hermesJobID
        }
        let directory = hermesRoot.appendingPathComponent("cron/output/\(jobID)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("# Pushed brief\n\nOne thing happened.\n".utf8)
            .write(to: directory.appendingPathComponent("2026-09-02_09-00-00.md"))
        return (jobID, { try? FileManager.default.removeItem(at: directory) })
    }

    /// Posts `body` to the push route, signed unless overridden.
    private static func push(
        _ client: some TestClientProtocol,
        _ hook: HermesMirrorWebhookDTO,
        body: String,
        secret: String,
        timestamp: String? = nil,
        signature: String? = nil,
        path: String? = nil
    ) async throws -> (status: HTTPResponse.Status, body: ByteBuffer) {
        let stamp = timestamp ?? String(Int(Date().timeIntervalSince1970))
        let data = Data(body.utf8)
        var headers: HTTPFields = [.contentType: "application/json"]
        let timestampField = try #require(HTTPField.Name(HermesMirrorWebhookController.timestampHeader))
        let signatureField = try #require(HTTPField.Name(HermesMirrorWebhookController.signatureHeader))
        headers[timestampField] = stamp
        headers[signatureField] = signature ?? WorkflowWebhookSignature.sign(secret: secret, timestamp: stamp, body: data)
        return try await client.execute(uri: path ?? hook.path, method: .post, headers: headers, body: ByteBuffer(string: body)) {
            ($0.status, $0.body)
        }
    }

    @Test
    func `rotate mints a one-time secret and the read-back never returns it`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let auth = try await Self.register(client: client)

            try await client.execute(uri: "/v1/hermes/mirror/webhook", method: .get, headers: auth) { response in
                #expect(response.status == .notFound)
                #expect(String(buffer: response.body).contains("hermes_webhook_not_configured"))
            }

            let hook = try await Self.rotate(client, auth)
            #expect(hook.secret?.isEmpty == false)
            #expect(hook.path == "/v1/hermes/mirror/webhook/\(hook.token)")
            #expect(hook.signatureHeader == "X-Webhook-Signature-V2")
            #expect(hook.replayWindowSeconds == 300)
            #expect(hook.rotatedAt != nil)

            try await client.execute(uri: "/v1/hermes/mirror/webhook", method: .get, headers: auth) { response in
                #expect(response.status == .ok)
                let read = try Self.decode(HermesMirrorWebhookDTO.self, response.body)
                #expect(read.token == hook.token)
                #expect(read.secret == nil)
            }

            // Rotating again replaces the token, so a leaked one dies.
            let rotated = try await Self.rotate(client, auth)
            #expect(rotated.token != hook.token)
            #expect(rotated.secret != hook.secret)

            // The push route is public; the credential routes are not.
            try await client.execute(uri: "/v1/hermes/mirror/webhook", method: .post) { response in
                #expect(response.status == .unauthorized)
            }
        }
    }

    @Test
    func `a signed push collects the job and agrees with the polling collect`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let auth = try await Self.register(client: client)
            let hook = try await Self.rotate(client, auth)
            let secret = try #require(hook.secret)
            let job = try await Self.seedJobWithOutput(client, auth)
            defer { job.cleanup() }

            let pushed = try await Self.push(client, hook, body: #"{"job_id":"\#(job.id)"}"#, secret: secret)
            #expect(pushed.status == .ok)
            let result = try Self.decode(HermesJobCollectResultDTO.self, pushed.body)
            #expect(result.hermesJobID == job.id)
            #expect(result.inserted == 1)
            #expect(result.filesWritten == 1)

            // The poll runs the same pass over the same run key, so it finds
            // nothing new — the push is latency, not a second source.
            try await client.execute(uri: "/v1/hermes/mirror/jobs/\(job.id)/collect", method: .post, headers: auth) { response in
                #expect(response.status == .ok)
                let polled = try Self.decode(HermesJobCollectResultDTO.self, response.body)
                #expect(polled.inserted == 0)
                #expect(polled.skipped == 1)
                #expect(polled.filesWritten == 0)
            }
            // …and a repeated push is equally harmless.
            let again = try await Self.push(client, hook, body: #"{"job_id":"\#(job.id)"}"#, secret: secret)
            #expect(again.status == .ok)
            #expect(try Self.decode(HermesJobCollectResultDTO.self, again.body).inserted == 0)

            try await client.execute(uri: "/v1/hermes/mirror/jobs/\(job.id)/runs", method: .get, headers: auth) { response in
                let runs = try Self.decode(HermesJobRunsResponse.self, response.body)
                #expect(runs.runs.count == 1)
                #expect(runs.runs[0].vaultFilePath?.contains("raw/jobs/") == true)
            }
        }
    }

    @Test
    func `unsigned, missigned, replayed and unknown pushes are all the same 401`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let auth = try await Self.register(client: client)
            let hook = try await Self.rotate(client, auth)
            let secret = try #require(hook.secret)
            let body = #"{"job_id":"nothing"}"#

            // Wrong secret.
            let forged = try await Self.push(client, hook, body: body, secret: "not-the-secret")
            #expect(forged.status == .unauthorized)
            #expect(String(buffer: forged.body).contains("hermes_webhook_unauthorized"))

            // Right secret, but the signature covers a different body — the
            // timestamp is bound in, so a captured signature cannot be reused
            // for new content.
            let swapped = try await Self.push(
                client, hook, body: body, secret: secret,
                signature: WorkflowWebhookSignature.sign(
                    secret: secret,
                    timestamp: String(Int(Date().timeIntervalSince1970)),
                    body: Data(#"{"job_id":"other"}"#.utf8)
                )
            )
            #expect(swapped.status == .unauthorized)

            // Correctly signed, but outside the replay window.
            let stale = String(Int(Date().timeIntervalSince1970) - 3600)
            let replayed = try await Self.push(client, hook, body: body, secret: secret, timestamp: stale)
            #expect(replayed.status == .unauthorized)

            // No signature headers at all.
            try await client.execute(
                uri: hook.path, method: .post,
                headers: [.contentType: "application/json"], body: ByteBuffer(string: body)
            ) { response in
                #expect(response.status == .unauthorized)
            }

            // An unknown token is refused with the same message as a bad
            // signature, so a sender cannot probe for live tokens.
            let unknown = try await Self.push(
                client, hook, body: body, secret: secret,
                path: "/v1/hermes/mirror/webhook/\(String(repeating: "0", count: 64))"
            )
            #expect(unknown.status == .unauthorized)
            #expect(String(buffer: unknown.body).contains("hermes_webhook_unauthorized"))
        }
    }

    @Test
    func `a signed push with a traversing job id never reaches Hermes`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let auth = try await Self.register(client: client)
            let hook = try await Self.rotate(client, auth)
            let secret = try #require(hook.secret)

            let traversal = try await Self.push(client, hook, body: #"{"job_id":"../etc"}"#, secret: secret)
            #expect(traversal.status == .badRequest)
            #expect(String(buffer: traversal.body).contains("hermes_mirror_invalid_path"))

            // A well-formed id this tenant does not mirror is not an error to
            // the sender: the poller owns correctness, so the push reports
            // zero counts rather than inviting a retry loop.
            let unknownJob = try await Self.push(client, hook, body: #"{"job_id":"no-such-job"}"#, secret: secret)
            #expect(unknownJob.status == .ok)
            let result = try Self.decode(HermesJobCollectResultDTO.self, unknownJob.body)
            #expect(result.inserted == 0)
            #expect(result.fetched == 0)
        }
    }

    @Test
    func `the admin_config_rw signal is what gates the credential`() {
        // The managed transport owns its Hermes' config on the PVC, so it
        // reports the capability; a dashboard that says nothing does not.
        #expect(HermesDashboardClient.adminConfigRW(["admin_config_rw": true]) == true)
        #expect(HermesDashboardClient.adminConfigRW(["capabilities": ["cron", "admin_config_rw"]]) == true)
        #expect(HermesDashboardClient.adminConfigRW(["capabilities": ["cron"]]) == false)
        #expect(HermesDashboardClient.adminConfigRW(["capabilities": ["admin_config_rw": false]]) == false)
        #expect(HermesDashboardClient.adminConfigRW(["version": "0.20.0"]) == nil)
    }
}
