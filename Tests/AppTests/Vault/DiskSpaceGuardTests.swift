@testable import App
import Configuration
import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import HummingbirdTesting
import Logging
import LuminaVaultShared
import Synchronization
import Testing

/// Free-space floors with an injected free-space source. The HTTP-level 507
/// contract is in `DiskSpaceGuardHTTPTests` below.
struct DiskSpaceGuardTests {
    private static let gib: Int64 = 1024 * 1024 * 1024

    /// Counts provider calls and lets a test move the clock and the reading.
    private final class Probe: Sendable {
        let calls = Mutex(0)
        let space: Mutex<DiskSpace?>
        let clock = Mutex(Date(timeIntervalSince1970: 1_800_000_000))

        init(free: Int64, total: Int64) {
            space = Mutex(DiskSpace(freeBytes: free, totalBytes: total))
        }

        func guardrail(minFreeBytes: Int64 = 3 * DiskSpaceGuardTests.gib, minFreeRatio: Double = 0.10) -> DiskSpaceGuard {
            DiskSpaceGuard(
                path: "/irrelevant",
                minFreeBytes: minFreeBytes,
                minFreeRatio: minFreeRatio,
                provider: { [self] _ in
                    calls.withLock { $0 += 1 }
                    guard let space = space.withLock({ $0 }) else { throw DiskSpaceGuardError.statvfsFailed(path: "/irrelevant", errno: 5) }
                    return space
                },
                now: { [self] in clock.withLock { $0 } },
                logger: Logger(label: "test.disk")
            )
        }
    }

    @Test
    func `allows a write that leaves both floors intact`() throws {
        let probe = Probe(free: 50 * Self.gib, total: 100 * Self.gib)
        try probe.guardrail().check(incomingBytes: 10 * Self.gib)
    }

    @Test
    func `rejects when the write would cross the byte floor`() {
        // 4 GiB free of 10 GiB total: the ratio floor (1 GiB) is fine, but a
        // 2 GiB write leaves 2 GiB < 3 GiB.
        let probe = Probe(free: 4 * Self.gib, total: 10 * Self.gib)
        #expect(throws: InsufficientStorageError.self) {
            try probe.guardrail().check(incomingBytes: 2 * Self.gib)
        }
    }

    @Test
    func `rejects when the write would cross the ratio floor`() {
        // 1 TiB volume: 120 GiB free clears 3 GiB easily, but a 30 GiB upload
        // leaves 90 GiB, under 10%.
        let probe = Probe(free: 120 * Self.gib, total: 1024 * Self.gib)
        #expect(throws: InsufficientStorageError.self) {
            try probe.guardrail().check(incomingBytes: 30 * Self.gib)
        }
    }

    @Test
    func `rejects even tiny writes once the volume is already low`() {
        let probe = Probe(free: 1 * Self.gib, total: 100 * Self.gib)
        #expect(throws: InsufficientStorageError.self) {
            try probe.guardrail().check(incomingBytes: 1)
        }
    }

    @Test
    func `zero floors only refuse what does not fit`() throws {
        let probe = Probe(free: 1000, total: 100 * Self.gib)
        let guardrail = probe.guardrail(minFreeBytes: 0, minFreeRatio: 0)
        try guardrail.check(incomingBytes: 1000)
        #expect(throws: InsufficientStorageError.self) {
            try guardrail.check(incomingBytes: 1001)
        }
    }

    @Test
    func `caches the measurement for a few seconds`() throws {
        let probe = Probe(free: 50 * Self.gib, total: 100 * Self.gib)
        let guardrail = probe.guardrail()
        for _ in 0 ..< 20 {
            try guardrail.check(incomingBytes: 1)
        }
        #expect(probe.calls.withLock { $0 } == 1)

        // The disk fills; a cached reading may lag by at most the TTL.
        probe.space.withLock { $0 = DiskSpace(freeBytes: Self.gib, totalBytes: 100 * Self.gib) }
        try guardrail.check(incomingBytes: 1)
        probe.clock.withLock { $0 = $0.addingTimeInterval(6) }
        #expect(throws: InsufficientStorageError.self) {
            try guardrail.check(incomingBytes: 1)
        }
        #expect(probe.calls.withLock { $0 } == 2)
    }

    @Test
    func `fails open when the volume cannot be measured`() throws {
        let probe = Probe(free: 0, total: 0)
        probe.space.withLock { $0 = nil }
        try probe.guardrail().check(incomingBytes: 10 * Self.gib)
    }

    @Test
    func `statvfs reads a real volume`() throws {
        let space = try DiskSpaceGuard.statvfsProvider(FileManager.default.temporaryDirectory.path)
        #expect(space.totalBytes > 0)
        #expect(space.freeBytes >= 0)
        #expect(space.freeBytes <= space.totalBytes)
        // A path that does not exist yet measures its nearest existing ancestor.
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("not-yet-\(UUID().uuidString)/deeper").path
        #expect(try DiskSpaceGuard.statvfsProvider(missing).totalBytes == space.totalBytes)
    }

    @Test
    func `507 body uses the coded error envelope`() throws {
        let error = InsufficientStorageError()
        #expect(error.status.code == 507)
        let json = try JSONSerialization.jsonObject(with: error.bodyData) as? [String: Any]
        let body = json?["error"] as? [String: Any]
        #expect(body?["code"] as? String == "insufficient_storage")
        #expect((body?["message"] as? String)?.isEmpty == false)
        #expect(body?["cta"] == nil)
    }
}

/// Routes that write user files answer 507 when the floor would be crossed.
/// No injection needed: a floor larger than any disk makes the real `statvfs`
/// reading fail it.
@Suite(.serialized, .tags(.integration), .integrationDatabase, .disabled(if: IntegrationTestEnv.skipIntegration))
struct DiskSpaceGuardHTTPTests {
    private static let password = "CorrectHorseBatteryStaple1!"

    private static var fullDiskReader: ConfigReader {
        dbTestReader(overriding: ["storage.minFreeBytes": cfg(Int(Int64.max / 2))])
    }

    private static func register(client: some TestClientProtocol) async throws -> AuthResponse {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        return try await client.execute(
            uri: "/v1/auth/register",
            method: .post,
            headers: [.contentType: "application/json"],
            body: ByteBuffer(string: #"{"email":"disk-\#(suffix)@test.luminavault","username":"disk-\#(suffix)","password":"\#(password)"}"#)
        ) { try testJSONDecoder().decode(AuthResponse.self, from: Data(buffer: $0.body)) }
    }

    private static func expectInsufficientStorage(_ response: TestResponse) throws {
        #expect(response.status.code == 507)
        let json = try JSONSerialization.jsonObject(with: Data(buffer: response.body)) as? [String: Any]
        #expect((json?["error"] as? [String: Any])?["code"] as? String == "insufficient_storage")
    }

    @Test
    func `vault upload, todo and capture are refused with 507 and nothing is written`() async throws {
        let app = try await buildApplication(reader: Self.fullDiskReader)
        try await app.test(.router) { client in
            let auth = try await Self.register(client: client)
            let bearer = "Bearer \(auth.accessToken)"

            try await client.execute(
                uri: "/v1/vault/files?path=inbox/full-disk.md",
                method: .post,
                headers: [.authorization: bearer, .contentType: "text/markdown"],
                body: ByteBuffer(string: "# would not fit")
            ) { try Self.expectInsufficientStorage($0) }

            try await client.execute(
                uri: "/v1/todos",
                method: .post,
                headers: [.authorization: bearer, .contentType: "application/json"],
                body: ByteBuffer(string: #"{"title":"buy disks"}"#)
            ) { try Self.expectInsufficientStorage($0) }

            try await client.execute(
                uri: "/v1/capture/safari",
                method: .post,
                headers: [.authorization: bearer, .contentType: "application/json"],
                body: ByteBuffer(string: #"{"url":"https://example.com/article"}"#)
            ) { try Self.expectInsufficientStorage($0) }

            try await withTestFluent(label: "test.disk.verify") { fluent in
                let rows = try await VaultFile.query(on: fluent.db(), tenantID: auth.userId).count()
                #expect(rows == 0, "a refused write must not leave a vault_files row")
            }
            let raw = VaultPathService(rootPath: "/tmp/luminavault-test").rawDirectory(for: auth.userId)
            #expect(!FileManager.default.fileExists(atPath: raw.appendingPathComponent("inbox/full-disk.md").path))
        }
    }

    @Test
    func `ingestion batch is refused before any row is created`() async throws {
        let app = try await buildApplication(reader: Self.fullDiskReader)
        try await app.test(.router) { client in
            let auth = try await Self.register(client: client)
            try await client.execute(
                uri: "/v1/ingestions",
                method: .post,
                headers: [.authorization: "Bearer \(auth.accessToken)", .contentType: "application/json"],
                body: ByteBuffer(string: #"{"items":[{"kind":"file","fileName":"big.pdf","contentType":"application/pdf","sizeBytes":1048576}]}"#)
            ) { try Self.expectInsufficientStorage($0) }

            try await withTestFluent(label: "test.disk.ingest") { fluent in
                let batches = try await IngestionBatch.query(on: fluent.db()).filter(\.$tenantID == auth.userId).count()
                #expect(batches == 0)
            }
        }
    }
}
