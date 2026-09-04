@testable import App
import Foundation
import Hummingbird
import HummingbirdTesting
import LuminaVaultShared
import Testing

/// Hermes Mirror task 6 — `/v1/hermes/mirror/*` end to end through the
/// managed (filesystem) transport rooted at the test `hermes.dataRoot`, plus
/// the `GET /v1/skills` merge and the `/run` refusal for `source: hermes`.
@Suite(.serialized, .tags(.integration), .integrationDatabase, .disabled(if: IntegrationTestEnv.skipIntegration))
struct HermesMirrorControllerTests {
    private static let hermesRoot = URL(fileURLWithPath: "/tmp/luminavault-test-hermes", isDirectory: true)

    private static func register(client: some TestClientProtocol) async throws -> String {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        let body = ByteBuffer(string: """
        {"email":"mirror-\(suffix)@test.luminavault","username":"mirror-\(suffix)","password":"CorrectHorseBatteryStaple1!"}
        """)
        let response = try await client.execute(uri: "/v1/auth/register", method: .post, headers: [.contentType: "application/json"], body: body) {
            try testJSONDecoder().decode(AuthResponse.self, from: Data(buffer: $0.body))
        }
        return response.accessToken
    }

    private static func decode<T: Decodable>(_: T.Type, _ buffer: ByteBuffer) throws -> T {
        try testJSONDecoder().decode(T.self, from: Data(buffer: buffer))
    }

    /// Writes a skill into the shared test Hermes home; returns a cleanup closure.
    private static func seedSkill(_ name: String) throws -> () -> Void {
        let dir = hermesRoot.appendingPathComponent("skills/\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("---\nname: \(name)\ndescription: Mirror test skill\n---\n# \(name)\n".utf8).write(to: dir.appendingPathComponent("SKILL.md"))
        return { try? FileManager.default.removeItem(at: dir) }
    }

    @Test
    func `unauthenticated requests are rejected`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/hermes/mirror/status", method: .get) { response in
                #expect(response.status == .unauthorized)
            }
        }
    }

    @Test
    func `status starts empty on the managed transport`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.register(client: client)
            try await client.execute(uri: "/v1/hermes/mirror/status", method: .get, headers: [.authorization: "Bearer \(token)"]) { response in
                #expect(response.status == .ok)
                let status = try Self.decode(HermesMirrorStatusDTO.self, response.body)
                #expect(status.transport == .managed)
                #expect(status.lastStatus == .never)
                #expect(status.skillsCount == 0)
                #expect(status.vaultState == .absent)
                #expect(status.dashboard == nil)
            }
        }
    }

    @Test
    func `sync mirrors managed skills, toggle writes through, and the catalog merges them`() async throws {
        let name = "mirror-skill-\(UUID().uuidString.prefix(6).lowercased())"
        let cleanup = try Self.seedSkill(name)
        defer { cleanup() }
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.register(client: client)
            let auth: HTTPFields = [.authorization: "Bearer \(token)", .contentType: "application/json"]

            try await client.execute(uri: "/v1/hermes/mirror/sync", method: .post, headers: auth, body: ByteBuffer(string: #"{"scope":["skills","jobs"]}"#)) { response in
                #expect(response.status == .ok)
                let status = try Self.decode(HermesMirrorStatusDTO.self, response.body)
                #expect(status.lastStatus == .ok)
                #expect(status.skillsCount >= 1)
                #expect(status.lastSyncAt != nil)
            }
            try await client.execute(uri: "/v1/hermes/mirror/skills", method: .get, headers: auth) { response in
                #expect(response.status == .ok)
                let skills = try Self.decode(HermesMirroredSkillsResponse.self, response.body).skills
                let mine = skills.first { $0.name == name }
                #expect(mine?.enabled == true)
                #expect(mine?.description == "Mirror test skill")
            }
            try await client.execute(uri: "/v1/hermes/mirror/skills/\(name)", method: .put, headers: auth, body: ByteBuffer(string: #"{"enabled":false}"#)) { response in
                #expect(response.status == .ok)
                let skill = try Self.decode(HermesMirroredSkillDTO.self, response.body)
                #expect(skill.enabled == false)
            }
            let disabled = FilesystemHermesTransport.readDisabledSkills(configURL: Self.hermesRoot.appendingPathComponent("config.yaml"))
            #expect(disabled.contains(name))
            try await client.execute(uri: "/v1/hermes/mirror/skills/\(name)", method: .put, headers: auth, body: ByteBuffer(string: #"{"enabled":true}"#)) { response in
                #expect(response.status == .ok)
            }
            try await client.execute(uri: "/v1/hermes/mirror/skills/not-a-skill", method: .put, headers: auth, body: ByteBuffer(string: #"{"enabled":true}"#)) { response in
                #expect(response.status == .notFound)
            }

            // GET /v1/skills appends the mirrored skill as source `hermes`, and `/run` refuses it.
            try await client.execute(uri: "/v1/skills", method: .get, headers: auth) { response in
                #expect(response.status == .ok)
                let list = try Self.decode(SkillListResponse.self, response.body)
                let mirrored = list.skills.first { $0.id == "hermes-\(name)" }
                #expect(mirrored?.source == .hermes)
                #expect(mirrored?.name == name)
                #expect(mirrored?.dailyRunCap == 0)
            }
            try await client.execute(uri: "/v1/skills/hermes-\(name)/run", method: .post, headers: auth, body: ByteBuffer(string: "{}")) { response in
                #expect(response.status == .badRequest)
                #expect(String(buffer: response.body).contains("hermes_skill_runs_on_hermes"))
            }
        }
    }

    @Test
    func `jobs, vault create, compile job install and import-sessions on the managed transport`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.register(client: client)
            let auth: HTTPFields = [.authorization: "Bearer \(token)", .contentType: "application/json"]

            try await client.execute(uri: "/v1/hermes/mirror/jobs", method: .get, headers: auth) { response in
                #expect(response.status == .ok)
                let jobs = try Self.decode(HermesMirroredJobsResponse.self, response.body)
                #expect(jobs.source == .live)
            }
            try await client.execute(uri: "/v1/hermes/mirror/vault/create", method: .post, headers: auth) { response in
                #expect(response.status == .ok)
                let created = try Self.decode(HermesVaultCreateResultDTO.self, response.body)
                #expect(created.vaultPath == Self.hermesRoot.appendingPathComponent("kb").path)
                var isDirectory: ObjCBool = false
                #expect(FileManager.default.fileExists(atPath: Self.hermesRoot.appendingPathComponent("kb/raw").path, isDirectory: &isDirectory))
                #expect(FileManager.default.fileExists(atPath: Self.hermesRoot.appendingPathComponent("kb/.kb/manifest.json").path))
            }
            try await client.execute(uri: "/v1/hermes/mirror/status", method: .get, headers: auth) { response in
                let status = try Self.decode(HermesMirrorStatusDTO.self, response.body)
                #expect(status.vaultState == .created || status.vaultState == .detected)
                #expect(status.vaultPath?.hasSuffix("/kb") == true)
            }
            var jobID = ""
            try await client.execute(uri: "/v1/hermes/mirror/jobs/install-compile", method: .post, headers: auth) { response in
                #expect(response.status == .ok)
                let result = try Self.decode(HermesCompileJobInstallResultDTO.self, response.body)
                #expect(result.schedule == HermesMirrorService.compileJobSchedule)
                jobID = result.jobID
            }
            try await client.execute(uri: "/v1/hermes/mirror/jobs/install-compile", method: .post, headers: auth) { response in
                let result = try Self.decode(HermesCompileJobInstallResultDTO.self, response.body)
                #expect(result.created == false)
                #expect(result.jobID == jobID)
            }
            try await client.execute(uri: "/v1/hermes/mirror/jobs", method: .get, headers: auth) { response in
                let jobs = try Self.decode(HermesMirroredJobsResponse.self, response.body)
                #expect(jobs.jobs.contains { $0.hermesJobID == jobID && $0.name == HermesMirrorService.compileJobName })
            }
            try await client.execute(uri: "/v1/hermes/mirror/vault/import", method: .post, headers: auth, body: ByteBuffer(string: #"{"vaultPath":"/tmp/../etc"}"#)) { response in
                #expect(response.status == .badRequest)
                #expect(String(buffer: response.body).contains("hermes_mirror_invalid_path"))
            }
            // Managed sessions ride the gateway api_server, which the test env does not run.
            try await client.execute(uri: "/v1/hermes/mirror/vault/import-sessions", method: .post, headers: auth) { response in
                #expect(response.status == .badGateway)
            }
        }
    }

    @Test
    func `transport errors map to stable status codes`() {
        #expect(HermesMirrorController.status(for: .invalidPath("x")) == .badRequest)
        #expect(HermesMirrorController.status(for: .bodyTooLarge(path: "x", limit: 1)) == .badRequest)
        #expect(HermesMirrorController.status(for: .notFound("x")) == .notFound)
        #expect(HermesMirrorController.status(for: .unsupported("sessions")) == .notImplemented)
        #expect(HermesMirrorController.status(for: .dashboardAuthModeUnsupported) == .badGateway)
        #expect(HermesMirrorController.status(for: .dashboardUnreachable("x")) == .badGateway)
        #expect(HermesMirrorTransportError.dashboardAuthModeUnsupported.code == "hermes_dashboard_auth_mode_unsupported")
    }
}
