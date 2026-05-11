import Foundation
import HummingbirdFluent
import Logging

/// HER-197 scaffold — resolves the Hermes gateway endpoint for a
/// tenant. Returns `(baseURL, authHeader)`.
///
/// Lookup order:
///   1. `user_hermes_config` row for `tenantID` (decrypts auth header
///      via `SecretBox`).
///   2. Managed default (`ServiceContainer.hermesGatewayURL`, no auth).
///
/// **Request-scoped caching is mandatory.** `HermesMemoryService` and
/// `MemoGeneratorService` issue multiple chat calls per agent loop;
/// each call must NOT round-trip to Postgres + KDF + AES-GCM. The
/// caller is expected to instantiate (or hold) one `Resolution` per
/// HTTP request and re-use it across the loop.
///
/// HER-197 implementation lands in follow-up commit; transport
/// refactor in `HermesMemoryService`, `MemoGeneratorService`,
/// `KBCompileService`, and `DefaultHermesLLMService` follows.
actor HermesEndpointResolver {
    /// Cached resolution. Construct once per request, pass into every
    /// downstream service. The auth header is plaintext here — never
    /// log it, never include it in tracing spans.
    struct Resolution: Sendable {
        let baseURL: URL
        let authHeader: String?
        let isUserOverride: Bool
    }

    private let fluent: Fluent
    private let secretBox: SecretBox
    private let ssrfGuard: SSRFGuard
    private let defaultBaseURL: URL
    private let logger: Logger

    init(
        fluent: Fluent,
        secretBox: SecretBox,
        ssrfGuard: SSRFGuard,
        defaultBaseURL: URL,
        logger: Logger,
    ) {
        self.fluent = fluent
        self.secretBox = secretBox
        self.ssrfGuard = ssrfGuard
        self.defaultBaseURL = defaultBaseURL
        self.logger = logger
    }

    /// HER-197 — looks up the row, decrypts, validates against SSRF
    /// guard, returns. The implementation MUST re-validate the URL
    /// against `SSRFGuard` (DNS rebinding defense) every time, not
    /// only on PUT.
    func resolve(tenantID _: UUID) async throws -> Resolution {
        Resolution(baseURL: defaultBaseURL, authHeader: nil, isUserOverride: false)
    }
}
