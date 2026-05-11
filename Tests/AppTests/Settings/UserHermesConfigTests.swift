@testable import App
import Foundation
import Testing

/// HER-197 scaffold smoke tests. Documents the `UserHermesConfig`
/// type surface + `HermesEndpointResolver` fallback contract.
///
/// The full E2E acceptance — PUT/GET round-trip, SSRF rejection list
/// (`127.0.0.1`, `192.168.0.1`, `10.0.0.5`, `::1`, `localhost`),
/// resolver returning override-vs-default, tenant isolation, stubbed
/// `URLProtocol` upstream — lands with the HER-197 follow-up commit
/// alongside the controller + transport refactor. Scaffold asserts
/// only what compiles today.
struct UserHermesConfigTests {
    @Test
    func `model uses expected schema name`() {
        #expect(UserHermesConfig.schema == "user_hermes_config")
    }

    @Test
    func `model conforms to TenantModel`() {
        // Compile-time check: only TenantModel exposes `tenantIDFieldKey`.
        #expect(UserHermesConfig.tenantIDFieldKey == "tenant_id")
    }

    // HER-197 follow-up — flip these to real assertions:
    //
    //   func `SSRFGuard rejects loopback and rfc1918`() async throws { ... }
    //   func `PUT then GET round-trips and never echoes auth header`() async throws { ... }
    //   func `resolver returns override when row exists, default otherwise`() async throws { ... }
    //   func `tenant A cannot read tenant B config`() async throws { ... }
    //   func `stubbed upstream receives traffic for override URL`() async throws { ... }
}
