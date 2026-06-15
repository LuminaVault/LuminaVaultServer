@testable import App
import Foundation
import Logging
import Testing

/// HER-240c — `LiveXaiOAuthBackend` happy path + error branches. Docker is
/// fully stubbed via `StubDockerExec` + `StubStreamingHandle`; no real
/// `docker` binary or Hermes container is touched.
@Suite(.serialized, .disabled(if: IntegrationTestEnv.runIntegrationOnly))
struct LiveXaiOAuthBackendTests {
    private static func makeHandle() -> HermesContainerHandle {
        HermesContainerHandle(
            tenantID: UUID(),
            containerName: "hermes-tenant-test",
            port: 9000,
            apiServerKey: "stub-key",
            xaiConnectedAt: nil,
            nousConnectedAt: nil
        )
    }

    private static func makeBackend(docker: StubDockerExec)
        -> (LiveXaiOAuthBackend, XaiOAuthProcessRegistry)
    {
        let registry = XaiOAuthProcessRegistry()
        let backend = LiveXaiOAuthBackend(
            docker: docker,
            registry: registry,
            logger: Logger(label: "test.her240c"),
            startTimeoutSeconds: 5,
            completeTimeoutSeconds: 5
        )
        return (backend, registry)
    }

    @Test
    func `requestAuthorizeURL extracts URL from Authorize prefix line`() async throws {
        let docker = StubDockerExec()
        let stream = StubStreamingHandle(lines: [
            "Hermes CLI v0.14",
            "Starting xai-oauth flow",
            "Authorize at: https://accounts.x.ai/oauth/authorize?client_id=hermes&state=abc",
        ])
        await docker.setNextStreamingHandle(stream)
        let (backend, registry) = Self.makeBackend(docker: docker)

        let url = try await backend.requestAuthorizeURL(
            handle: Self.makeHandle(),
            sessionID: "sess-1"
        )
        #expect(url == "https://accounts.x.ai/oauth/authorize?client_id=hermes&state=abc")
        #expect(await registry.count() == 1)
    }

    @Test
    func `requestAuthorizeURL accepts bare https x_ai URL on its own line`() async throws {
        let docker = StubDockerExec()
        let stream = StubStreamingHandle(lines: [
            "Hermes CLI v0.14",
            "https://accounts.x.ai/oauth/authorize?xyz=1",
        ])
        await docker.setNextStreamingHandle(stream)
        let (backend, _) = Self.makeBackend(docker: docker)
        let url = try await backend.requestAuthorizeURL(
            handle: Self.makeHandle(),
            sessionID: "sess-2"
        )
        #expect(url.hasPrefix("https://accounts.x.ai/"))
    }

    @Test
    func `requestAuthorizeURL throws when no matching line is emitted`() async throws {
        let docker = StubDockerExec()
        let stream = StubStreamingHandle(lines: ["unrelated banner"])
        await docker.setNextStreamingHandle(stream)
        stream.finishLines()
        let (backend, _) = Self.makeBackend(docker: docker)
        await #expect(throws: XaiOAuthError.authorizeURLMissingFromStdout) {
            _ = try await backend.requestAuthorizeURL(
                handle: Self.makeHandle(),
                sessionID: "sess-3"
            )
        }
    }

    @Test
    func `submitCallback forwards captured query to loopback and awaits exit`() async throws {
        let docker = StubDockerExec()
        let stream = StubStreamingHandle(lines: [
            "Authorize at: https://accounts.x.ai/oauth/authorize",
        ], exitCode: 0)
        await docker.setNextStreamingHandle(stream)
        let (backend, _) = Self.makeBackend(docker: docker)
        _ = try await backend.requestAuthorizeURL(
            handle: Self.makeHandle(),
            sessionID: "sess-4"
        )

        // Trigger the streaming handle to "complete" once submit runs.
        Task {
            try await Task.sleep(nanoseconds: 100_000_000)
            stream.finishLines()
        }

        let ok = try await backend.submitCallback(
            handle: Self.makeHandle(),
            sessionID: "sess-4",
            callbackURL: "http://127.0.0.1:56121/callback?code=abc&state=xyz"
        )
        #expect(ok)

        let invocations = await docker.invocations
        let curlExec = invocations.first { inv in
            inv.kind == "exec" && inv.args.first == "curl"
        }
        #expect(curlExec != nil, "submitCallback must run a curl exec to forward the callback")
        let curlURL = curlExec?.args.last ?? ""
        #expect(curlURL.contains("code=abc"))
        #expect(curlURL.contains("state=xyz"))
        #expect(curlURL.hasPrefix("http://127.0.0.1:56121/callback"))
    }

    @Test
    func `submitCallback throws sessionNotFound when registry is empty`() async throws {
        let docker = StubDockerExec()
        let (backend, _) = Self.makeBackend(docker: docker)
        await #expect(throws: XaiOAuthError.sessionNotFound) {
            _ = try await backend.submitCallback(
                handle: Self.makeHandle(),
                sessionID: "missing",
                callbackURL: "http://127.0.0.1:56121/callback?code=x"
            )
        }
    }

    @Test
    func `cancel removes registry entry`() async throws {
        let docker = StubDockerExec()
        let stream = StubStreamingHandle(lines: ["Authorize at: https://accounts.x.ai/foo"])
        await docker.setNextStreamingHandle(stream)
        let (backend, registry) = Self.makeBackend(docker: docker)
        _ = try await backend.requestAuthorizeURL(
            handle: Self.makeHandle(),
            sessionID: "sess-5"
        )
        #expect(await registry.count() == 1)
        await backend.cancel(sessionID: "sess-5")
        #expect(await registry.count() == 0)
    }

    @Test
    func `revoke shells out to hermes auth remove`() async throws {
        let docker = StubDockerExec()
        let (backend, _) = Self.makeBackend(docker: docker)
        let ok = try await backend.revoke(handle: Self.makeHandle())
        #expect(ok)
        let invocations = await docker.invocations
        let revokeExec = invocations.first { inv in
            inv.kind == "exec" && inv.args.contains("remove")
        }
        #expect(revokeExec?.args.contains("xai-oauth") == true)
    }

    // MARK: - Pure-function unit tests

    @Test
    func `forwardURL preserves query string from captured URL`() {
        let result = LiveXaiOAuthBackend.forwardURL(
            loopback: "http://127.0.0.1:56121/callback",
            captured: "http://example.com/redirect?code=ABC&state=XYZ"
        )
        #expect(result == "http://127.0.0.1:56121/callback?code=ABC&state=XYZ")
    }

    @Test
    func `forwardURL returns base when captured has no query`() {
        let result = LiveXaiOAuthBackend.forwardURL(
            loopback: "http://127.0.0.1:56121/callback",
            captured: "http://example.com/redirect"
        )
        #expect(result == "http://127.0.0.1:56121/callback")
    }
}
