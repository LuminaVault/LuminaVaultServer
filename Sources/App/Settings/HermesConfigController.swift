import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import Logging

/// HER-217 — `/v1/settings/hermes` GET/PUT/DELETE/test
/// (HER-197 follow-up — real handlers).
///
/// JWT + `userOrIP` rate-limit (set up in `App+build.swift`). Every
/// PUT re-encrypts the auth header through `SecretBox` and resets
/// `verified_at`. `GET` reports only `{ baseUrl, hasAuthHeader,
/// verifiedAt }` — the cleartext header is never echoed. `DELETE`
/// drops the row. `POST .../test` issues a probe request to
/// `<baseUrl>/v1/models` (fallback `/healthz`); on 2xx it sets
/// `verified_at = NOW()`.
struct HermesConfigController {
    struct GetResponse: Codable, ResponseEncodable {
        let baseUrl: String
        let hasAuthHeader: Bool
        let verifiedAt: Date?
    }

    struct PutRequest: Codable {
        let baseUrl: String
        let authHeader: String?
    }

    struct TestResponse: Codable, ResponseEncodable {
        let verifiedAt: Date
    }

    /// Stable error codes surfaced on `POST .../test` failure. iOS keys
    /// off these to render an actionable error banner. Upstream response
    /// bodies are NEVER forwarded — they may leak provider information.
    enum TestError: String {
        case timeout
        case tlsError = "tls_error"
        case http4xx = "http_4xx"
        case http5xx = "http_5xx"
        case ssrfRejected = "ssrf_rejected"
        case decryptFailed = "decrypt_failed"
        case unreachable
    }

    let fluent: Fluent
    let secretBox: SecretBox
    let ssrfGuard: SSRFGuard
    let probeSession: URLSession
    let logger: Logger

    init(
        fluent: Fluent,
        secretBox: SecretBox,
        ssrfGuard: SSRFGuard,
        probeSession: URLSession = .shared,
        logger: Logger,
    ) {
        self.fluent = fluent
        self.secretBox = secretBox
        self.ssrfGuard = ssrfGuard
        self.probeSession = probeSession
        self.logger = logger
    }

    func addRoutes(to router: RouterGroup<AppRequestContext>) {
        router.get(use: get)
        router.put(use: put)
        router.delete(use: delete)
        router.post("test", use: test)
    }

    // MARK: - GET

    @Sendable
    func get(_: Request, ctx: AppRequestContext) async throws -> GetResponse {
        let tenantID = try ctx.requireTenantID()
        guard let row = try await loadRow(tenantID: tenantID) else {
            throw HTTPError(.notFound, message: "no_hermes_config")
        }
        return GetResponse(
            baseUrl: row.baseURL,
            hasAuthHeader: row.authHeaderCiphertext != nil,
            verifiedAt: row.verifiedAt,
        )
    }

    // MARK: - PUT

    @Sendable
    func put(_ req: Request, ctx: AppRequestContext) async throws -> GetResponse {
        let tenantID = try ctx.requireTenantID()
        let body = try await req.decode(as: PutRequest.self, context: ctx)

        // Validate URL syntactically + resolve + classify before we accept
        // it. Reject everything SSRFGuard would reject at request time.
        let validatedURL: URL
        do {
            validatedURL = try await ssrfGuard.validate(rawURL: body.baseUrl)
        } catch let rejection as SSRFGuard.Rejection {
            throw HTTPError(
                .badRequest,
                message: "invalid_base_url:\(rejection)",
            )
        }

        let ciphertext: Data?
        let nonce: Data?
        if let header = body.authHeader, !header.isEmpty {
            let sealed: SecretBox.Sealed
            do {
                sealed = try secretBox.seal(header, tenantID: tenantID)
            } catch {
                logger.error(
                    "secretbox seal failed",
                    metadata: ["tenant": .string(tenantID.uuidString)],
                )
                throw HTTPError(.internalServerError, message: "seal_failed")
            }
            ciphertext = sealed.ciphertext
            nonce = sealed.nonce
        } else {
            ciphertext = nil
            nonce = nil
        }

        let db = fluent.db()
        let existing = try await loadRow(tenantID: tenantID)
        let row = existing ?? UserHermesConfig()
        row.tenantID = tenantID
        row.baseURL = validatedURL.absoluteString
        row.authHeaderCiphertext = ciphertext
        row.authHeaderNonce = nonce
        row.verifiedAt = nil
        try await row.save(on: db)

        return GetResponse(
            baseUrl: row.baseURL,
            hasAuthHeader: row.authHeaderCiphertext != nil,
            verifiedAt: row.verifiedAt,
        )
    }

    // MARK: - DELETE

    @Sendable
    func delete(_: Request, ctx: AppRequestContext) async throws -> Response {
        let tenantID = try ctx.requireTenantID()
        let db = fluent.db()
        if let row = try await loadRow(tenantID: tenantID) {
            try await row.delete(on: db)
        }
        return Response(status: .noContent)
    }

    // MARK: - POST /test

    @Sendable
    func test(_: Request, ctx: AppRequestContext) async throws -> TestResponse {
        let tenantID = try ctx.requireTenantID()
        guard let row = try await loadRow(tenantID: tenantID) else {
            throw HTTPError(.notFound, message: "no_hermes_config")
        }

        // Re-validate at probe time. PUT validated minutes ago; a malicious
        // DNS provider could have rebound the host in the interim.
        let baseURL: URL
        do {
            baseURL = try await ssrfGuard.validate(rawURL: row.baseURL)
        } catch let rejection as SSRFGuard.Rejection {
            logger.warning(
                "ssrf rejection during test",
                metadata: [
                    "tenant": .string(tenantID.uuidString),
                    "rejection": .string(String(describing: rejection)),
                ],
            )
            throw HTTPError(
                .badGateway,
                message: TestError.ssrfRejected.rawValue,
            )
        }

        let authHeader: String?
        if let ct = row.authHeaderCiphertext, let nonce = row.authHeaderNonce {
            do {
                authHeader = try secretBox.open(
                    SecretBox.Sealed(ciphertext: ct, nonce: nonce),
                    tenantID: tenantID,
                )
            } catch {
                throw HTTPError(
                    .badGateway,
                    message: TestError.decryptFailed.rawValue,
                )
            }
        } else {
            authHeader = nil
        }

        let probeError = await probe(baseURL: baseURL, authHeader: authHeader)
        if let probeError {
            throw HTTPError(
                .badGateway,
                message: probeError.rawValue,
            )
        }

        let now = Date()
        row.verifiedAt = now
        try await row.save(on: fluent.db())
        return TestResponse(verifiedAt: now)
    }

    // MARK: - helpers

    private func loadRow(tenantID: UUID) async throws -> UserHermesConfig? {
        try await UserHermesConfig.query(on: fluent.db())
            .filter(\.$tenantID == tenantID)
            .first()
    }

    /// Probes `<baseURL>/v1/models` first, then `<baseURL>/healthz` on
    /// 404. Returns `nil` on 2xx (verified) or a stable error code.
    /// Upstream response bodies are never forwarded.
    private func probe(baseURL: URL, authHeader: String?) async -> TestError? {
        if let err = await probeOne(
            url: baseURL.appendingPathComponent("v1/models"),
            authHeader: authHeader,
        ) {
            switch err {
            case .http4xx:
                // Models endpoint may not exist on a minimal Hermes — try the
                // health endpoint before giving up.
                return await probeOne(
                    url: baseURL.appendingPathComponent("healthz"),
                    authHeader: authHeader,
                )
            default:
                return err
            }
        }
        return nil
    }

    private func probeOne(url: URL, authHeader: String?) async -> TestError? {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 10
        if let authHeader {
            req.setValue(authHeader, forHTTPHeaderField: "Authorization")
        }
        do {
            let (_, response) = try await probeSession.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                return .unreachable
            }
            switch http.statusCode {
            case 200...299:
                return nil
            case 400...499:
                return .http4xx
            case 500...599:
                return .http5xx
            default:
                return .unreachable
            }
        } catch let err as URLError {
            switch err.code {
            case .timedOut:
                return .timeout
            case .secureConnectionFailed,
                 .serverCertificateUntrusted,
                 .serverCertificateHasBadDate,
                 .serverCertificateHasUnknownRoot,
                 .serverCertificateNotYetValid,
                 .clientCertificateRejected,
                 .clientCertificateRequired:
                return .tlsError
            default:
                return .unreachable
            }
        } catch {
            return .unreachable
        }
    }
}
