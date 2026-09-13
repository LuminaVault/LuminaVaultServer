@testable import App
import Foundation
import Hummingbird
import HummingbirdTesting
import Testing

/// HER-240 — the legacy `/v1/kb-compile` paths permanently redirect to
/// `/v1/memory-compile`.
///
/// Nothing covered this. The suites that exercised compile behaviour were
/// still calling the legacy paths, so they received the redirect instead of
/// the endpoint and failed on the empty body — 28 failures that read as
/// compile bugs and were really a stale URL. They now call the canonical
/// routes, which leaves the alias itself untested.
///
/// That matters more than it sounds: the alias exists so shipped iOS clients
/// keep working until they migrate, and it is meant to be retired next
/// milestone. A redirect nobody asserts can break silently, and the breakage
/// lands on old clients rather than in CI.
@Suite(.serialized, .tags(.integration), .integrationDatabase, .disabled(if: IntegrationTestEnv.skipIntegration))
struct LegacyCompileAliasTests {
    /// No bearer token here on purpose: the alias is registered bare, ahead of
    /// the authenticated group, so it answers before auth runs. A caller with
    /// a stale URL should be told where the route moved, not that they are
    /// unauthorised.
    @Test
    func `legacy compile path redirects to the canonical route`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/v1/kb-compile",
                method: .post,
                headers: [.contentType: "application/json"],
                body: ByteBuffer(string: "{}")
            ) { response in
                #expect(response.status == .permanentRedirect)
                #expect(response.headers[.location] == "/v1/memory-compile")
            }
        }
    }

    @Test
    func `legacy pending path redirects to the canonical route`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/v1/kb-compile/pending",
                method: .get
            ) { response in
                #expect(response.status == .permanentRedirect)
                #expect(response.headers[.location] == "/v1/memory-compile/pending")
            }
        }
    }
}
