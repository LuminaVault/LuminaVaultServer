import FluentKit
import Foundation
import HummingbirdFluent
import Logging

/// HER-217 — resolves the Hermes gateway endpoint for a tenant
/// (HER-197 follow-up).
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
/// Errors during decrypt / SSRF revalidation propagate to the caller
/// as `ResolutionError` so the chat endpoint can return 502 with
/// "Your Hermes gateway is unreachable, check Settings". They do NOT
/// silently fall back to the managed default — that would surprise
/// users who deliberately routed traffic away from the managed gateway.
actor HermesEndpointResolver {
    /// Cached resolution. Construct once per request, pass into every
    /// downstream service. The auth header is plaintext here — never
    /// log it, never include it in tracing spans.
    struct Resolution: Sendable {
        let baseURL: URL
        let authHeader: String?
        let isUserOverride: Bool
    }

    enum ResolutionError: Swift.Error, Equatable {
        case decryptFailed
        case ssrfRejected(String)
        case malformedRow
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

    /// Lookup → decrypt → SSRF re-validate (every call, defends DNS
    /// rebinding) → return.
    func resolve(tenantID: UUID) async throws -> Resolution {
        let row = try await UserHermesConfig.query(on: fluent.db())
            .filter(\.$tenantID == tenantID)
            .first()
        guard let row else {
            return Resolution(
                baseURL: defaultBaseURL,
                authHeader: nil,
                isUserOverride: false,
            )
        }

        let validated: URL
        do {
            validated = try await ssrfGuard.validate(rawURL: row.baseURL)
        } catch let rejection as SSRFGuard.Rejection {
            logger.warning(
                "ssrf rejection during resolve",
                metadata: [
                    "tenant": .string(tenantID.uuidString),
                    "rejection": .string(String(describing: rejection)),
                ],
            )
            throw ResolutionError.ssrfRejected(String(describing: rejection))
        }

        let authHeader: String?
        if let ct = row.authHeaderCiphertext, let nonce = row.authHeaderNonce {
            do {
                authHeader = try secretBox.open(
                    SecretBox.Sealed(ciphertext: ct, nonce: nonce),
                    tenantID: tenantID,
                )
            } catch {
                logger.error(
                    "auth header decrypt failed",
                    metadata: ["tenant": .string(tenantID.uuidString)],
                )
                throw ResolutionError.decryptFailed
            }
        } else if row.authHeaderCiphertext != nil || row.authHeaderNonce != nil {
            // One column populated and not the other — corrupt row.
            throw ResolutionError.malformedRow
        } else {
            authHeader = nil
        }

        return Resolution(
            baseURL: validated,
            authHeader: authHeader,
            isUserOverride: true,
        )
    }
}
