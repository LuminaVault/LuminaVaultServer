import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import Logging
import LuminaVaultShared

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

extension ProviderCredentialDTO: @retroactive ResponseEncodable {}
extension ProviderCredentialsListResponse: @retroactive ResponseEncodable {}
extension ProviderTestResponse: @retroactive ResponseEncodable {}
extension ProviderModelsResponse: @retroactive ResponseEncodable {}
extension ProviderPoolKeyDTO: @retroactive ResponseEncodable {}
extension ProviderPoolListResponse: @retroactive ResponseEncodable {}

/// HER-252 — `/v1/me/providers` GET/PUT/DELETE + `POST /test`.
///
/// Plaintext credentials are never echoed: the DTO carries `hasCredential`
/// only. PUT runs through `UserCredentialStore.upsert` (encrypts via
/// SecretBox + resets verified_at). POST /test issues a 1-token chat
/// request against the user's credential, classifies the response with
/// `ProviderErrorClassifier`, and stamps `verified_at` on success or
/// `last_failure_*` on failure.
struct ProvidersController {
    enum TestError: String {
        case noCredential = "no_credential"
        case unsupportedProvider = "unsupported_provider"
        case timeout
        case tlsError = "tls_error"
        case creditExhausted = "credit_exhausted"
        case rateLimit = "rate_limit"
        case upstreamError = "upstream_error"
        case upstreamRejected = "upstream_rejected"
        case network
    }

    let credentialStore: UserCredentialStore
    let fluent: Fluent
    let probeSession: URLSession
    let logger: Logger

    init(credentialStore: UserCredentialStore, fluent: Fluent, probeSession: URLSession = .shared, logger: Logger) {
        self.credentialStore = credentialStore
        self.fluent = fluent
        self.probeSession = probeSession
        self.logger = logger
    }

    func addRoutes(to router: RouterGroup<AppRequestContext>) {
        router.get(use: list)
        router.put(":provider", use: put)
        router.delete(":provider", use: delete)
        router.post(":provider/test", use: test)
        router.get(":provider/models", use: models)
        // Round-robin credential pool (Phase 2 item 6, layer 2).
        router.get(":provider/pool", use: listPool)
        router.post(":provider/pool", use: addPool)
        router.delete(":provider/pool/:keyID", use: deletePool)
    }

    // MARK: - Credential pool

    @Sendable
    func listPool(_: Request, ctx: AppRequestContext) async throws -> ProviderPoolListResponse {
        let tenantID = try ctx.requireTenantID()
        let providerID = try parseProvider(ctx)
        let rows = try await credentialStore.listPoolKeys(tenantID: tenantID, provider: serverKind(for: providerID))
        let keys = rows.map { ProviderPoolKeyDTO(id: $0.id ?? UUID(), label: $0.label, createdAt: $0.createdAt) }
        return ProviderPoolListResponse(provider: providerID, keys: keys)
    }

    @Sendable
    func addPool(_ req: Request, ctx: AppRequestContext) async throws -> ProviderPoolKeyDTO {
        let tenantID = try ctx.requireTenantID()
        let providerID = try parseProvider(ctx)
        let body = try await req.decode(as: ProviderPoolAddRequest.self, context: ctx)
        guard !body.apiKey.isEmpty else {
            throw HTTPError(.badRequest, message: "api_key_required")
        }
        let row = try await credentialStore.addPoolKey(
            tenantID: tenantID,
            provider: serverKind(for: providerID),
            apiKey: body.apiKey,
            label: body.label
        )
        return ProviderPoolKeyDTO(id: row.id ?? UUID(), label: row.label, createdAt: row.createdAt)
    }

    @Sendable
    func deletePool(_: Request, ctx: AppRequestContext) async throws -> Response {
        let tenantID = try ctx.requireTenantID()
        let providerID = try parseProvider(ctx)
        guard let raw = ctx.parameters.get("keyID"), let keyID = UUID(uuidString: raw) else {
            throw HTTPError(.badRequest, message: "invalid_key_id")
        }
        try await credentialStore.deletePoolKey(tenantID: tenantID, provider: serverKind(for: providerID), id: keyID)
        return Response(status: .noContent)
    }

    // MARK: - GET /v1/me/providers

    @Sendable
    func list(_: Request, ctx: AppRequestContext) async throws -> ProviderCredentialsListResponse {
        let tenantID = try ctx.requireTenantID()
        let rows = try await UserProviderCredential.query(on: fluent.db())
            .filter(\.$tenantID == tenantID)
            .all()
        var byProvider: [String: UserProviderCredential] = [:]
        for row in rows {
            byProvider[row.provider] = row
        }
        let dtos = ProviderID.allCases.map { providerID -> ProviderCredentialDTO in
            let providerKind = serverKind(for: providerID)
            let row = byProvider[providerKind.rawValue]
            let kind = row.flatMap { ProviderCredentialKind(rawValue: $0.credentialKind) } ?? defaultKind(for: providerID)
            // oauth marker rows (xAI SuperGrok linked account) have no ciphertext/base
            // but count as "has credential" because the connection itself authorizes use.
            let hasCredential = (row?.ciphertext != nil) || (row?.baseURL != nil) || (kind == .oauth)
            return ProviderCredentialDTO(
                provider: providerID,
                kind: kind,
                hasCredential: hasCredential,
                baseUrl: row?.baseURL,
                label: row?.label,
                verifiedAt: row?.verifiedAt,
                lastFailureAt: row?.lastFailureAt,
                lastFailureCode: row?.lastFailureCode
            )
        }
        return ProviderCredentialsListResponse(providers: dtos)
    }

    // MARK: - PUT /v1/me/providers/{provider}

    @Sendable
    func put(_ req: Request, ctx: AppRequestContext) async throws -> ProviderCredentialDTO {
        let tenantID = try ctx.requireTenantID()
        let providerID = try parseProvider(ctx)
        let kind = serverKind(for: providerID)
        let body = try await req.decode(as: ProviderCredentialPutRequest.self, context: ctx)

        // Validate kind/payload coherence. apiKey requires non-empty key;
        // hostURL requires baseUrl; oauth requires neither (handled by
        // upstream OAuth flow).
        switch body.kind {
        case .apiKey:
            guard let key = body.apiKey, !key.isEmpty else {
                throw HTTPError(.badRequest, message: "api_key_required")
            }
        case .hostURL:
            guard let url = body.baseUrl, !url.isEmpty else {
                throw HTTPError(.badRequest, message: "base_url_required")
            }
            guard URL(string: url) != nil else {
                throw HTTPError(.badRequest, message: "invalid_base_url")
            }
        case .oauth:
            break
        }

        do {
            try await credentialStore.upsert(
                tenantID: tenantID,
                provider: kind,
                credentialKind: body.kind.rawValue,
                apiKey: body.apiKey,
                baseURL: body.baseUrl,
                label: body.label
            )
        } catch {
            logger.error("provider credential upsert failed: \(error)")
            throw HTTPError(.internalServerError, message: "credential_save_failed")
        }
        // Re-fetch to return canonical view.
        let rows = try await UserProviderCredential.query(on: fluent.db())
            .filter(\.$tenantID == tenantID)
            .filter(\.$provider == kind.rawValue)
            .all()
        let row = rows.first
        let hasCredential = (row?.ciphertext != nil) || (row?.baseURL != nil) || (body.kind == .oauth)
        return ProviderCredentialDTO(
            provider: providerID,
            kind: body.kind,
            hasCredential: hasCredential,
            baseUrl: row?.baseURL,
            label: row?.label,
            verifiedAt: row?.verifiedAt,
            lastFailureAt: row?.lastFailureAt,
            lastFailureCode: row?.lastFailureCode
        )
    }

    // MARK: - DELETE /v1/me/providers/{provider}

    @Sendable
    func delete(_: Request, ctx: AppRequestContext) async throws -> Response {
        let tenantID = try ctx.requireTenantID()
        let providerID = try parseProvider(ctx)
        try await credentialStore.delete(tenantID: tenantID, provider: serverKind(for: providerID))
        return Response(status: .noContent)
    }

    // MARK: - POST /v1/me/providers/{provider}/test

    @Sendable
    func test(_: Request, ctx: AppRequestContext) async throws -> ProviderTestResponse {
        let tenantID = try ctx.requireTenantID()
        let providerID = try parseProvider(ctx)
        let kind = serverKind(for: providerID)
        guard let resolved = try await credentialStore.credential(for: kind, tenantID: tenantID) else {
            throw HTTPError(.badRequest, message: TestError.noCredential.rawValue)
        }

        // Build a one-off adapter using the user's resolved creds and
        // send a `max_tokens: 1` ping. Reuses ProviderErrorClassifier so
        // mapping to a stable code is consistent with the runtime path.
        let pingPayload = Self.pingPayload(for: providerID)
        let payload = JSON.encode(pingPayload)

        do {
            let adapter = try buildAdapter(kind: kind, resolved: resolved)
            _ = try await adapter.chatCompletionsWithMetadata(payload: payload, sessionKey: tenantID.uuidString, sessionID: nil)
            // Success — stamp verified_at.
            try await credentialStore.recordSuccess(tenantID: tenantID, provider: kind)
            return ProviderTestResponse(verifiedAt: Date(), model: pingPayload["model"] as? String)
        } catch let error as ProviderError {
            try? await credentialStore.recordFailure(
                tenantID: tenantID,
                provider: kind,
                code: error.reasonCode
            )
            throw HTTPError(.badGateway, message: stableCode(for: error).rawValue)
        } catch {
            try? await credentialStore.recordFailure(
                tenantID: tenantID,
                provider: kind,
                code: TestError.network.rawValue
            )
            throw HTTPError(.badGateway, message: TestError.network.rawValue)
        }
    }

    // MARK: - GET /v1/me/providers/{provider}/models

    /// Dynamic model listing. For OpenAI-compatible providers we fetch the
    /// upstream `/v1/models` (using the user's stored key when present) so
    /// the client picker stays current with rotating model lists (e.g. Nous
    /// free models). Any failure — unsupported provider, no credential,
    /// network, non-2xx, or unparseable body — falls back to the offline
    /// `LLMModelCatalog` with `fetchedLive: false`. Never throws on the
    /// fetch path: a stale upstream must not break the picker.
    @Sendable
    func models(_: Request, ctx: AppRequestContext) async throws -> ProviderModelsResponse {
        let tenantID = try ctx.requireTenantID()
        let providerID = try parseProvider(ctx)
        let kind = serverKind(for: providerID)

        func fallback() -> ProviderModelsResponse {
            ProviderModelsResponse(
                provider: providerID,
                models: LLMModelCatalog.models(for: providerID),
                fetchedLive: false
            )
        }

        // Only OpenAI-compatible providers expose a standard `/v1/models`.
        // Anthropic / Gemini / Ollama keep the curated catalog.
        guard [.xai, .nvidia, .openai, .openRouter, .nous].contains(kind) else {
            return fallback()
        }

        // `try?` over a throwing `-> ResolvedCredential?` yields a double
        // optional; flatten with `?? nil`.
        let resolved = await (try? credentialStore.credential(for: kind, tenantID: tenantID)) ?? nil
        let key = resolved?.apiKey
        let base = resolved?.baseURL ?? OpenAICompatibleAdapter.defaultBaseURL(for: kind)
        let url = base.appendingPathComponent("v1").appendingPathComponent("models")

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 8
        if let key, !key.isEmpty {
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        if kind == .openRouter {
            req.setValue("https://luminavault.app", forHTTPHeaderField: "HTTP-Referer")
            req.setValue("LuminaVault", forHTTPHeaderField: "X-Title")
        }

        guard
            let (data, response) = try? await probeSession.data(for: req),
            let http = response as? HTTPURLResponse,
            (200 ..< 300).contains(http.statusCode),
            let parsed = Self.parseModels(data)
        else {
            return fallback()
        }
        guard !parsed.isEmpty else { return fallback() }
        return ProviderModelsResponse(provider: providerID, models: parsed, fetchedLive: true)
    }

    /// Parse a standard OpenAI `/v1/models` body — `{ "data": [{ "id": …,
    /// "name": … }] }` — into `[LLMModelInfo]`. `name` is used for the label
    /// when present (Nous supplies it), else the id is shown verbatim.
    static func parseModels(_ data: Data) -> [LLMModelInfo]? {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let list = root["data"] as? [[String: Any]]
        else { return nil }
        let models: [LLMModelInfo] = list.compactMap { entry in
            guard let id = entry["id"] as? String, !id.isEmpty else { return nil }
            let label = (entry["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id
            return LLMModelInfo(id: id, displayName: label)
        }
        return models
    }

    // MARK: - Helpers

    private func parseProvider(_ ctx: AppRequestContext) throws -> ProviderID {
        let raw = try ctx.parameters.require("provider", as: String.self)
        guard let provider = ProviderID(rawValue: raw) else {
            throw HTTPError(.notFound, message: TestError.unsupportedProvider.rawValue)
        }
        return provider
    }

    /// Map a `ProviderID` (wire) to the server-internal `ProviderKind`.
    /// 1:1 today; kept as a helper so future divergence (e.g. multiple
    /// xAI backends under one wire-side ID) is contained.
    private func serverKind(for id: ProviderID) -> ProviderKind {
        switch id {
        case .xai: .xai
        case .nvidia: .nvidia
        case .anthropic: .anthropic
        case .openai: .openai
        case .ollama: .ollama
        case .openRouter: .openRouter
        case .gemini: .gemini
        case .nous: .nous
        }
    }

    private func defaultKind(for id: ProviderID) -> ProviderCredentialKind {
        switch id {
        case .xai, .nvidia, .anthropic, .openai, .openRouter, .gemini, .nous: .apiKey
        case .ollama: .hostURL
        }
    }

    private func buildAdapter(kind: ProviderKind, resolved: UserCredentialStore.ResolvedCredential) throws -> any ProviderAdapter {
        let key = resolved.apiKey ?? ""
        switch kind {
        case .anthropic:
            let base = resolved.baseURL ?? URL(string: "https://api.anthropic.com")!
            return AnthropicAdapter(apiKey: key, baseURL: base, session: probeSession, logger: logger)
        case .ollama:
            let base = resolved.baseURL ?? URL(string: "http://localhost:11434")!
            return OllamaAdapter(defaultBaseURL: base, session: probeSession, logger: logger)
        case .xai, .nvidia, .openai, .openRouter, .nous:
            let base = resolved.baseURL ?? OpenAICompatibleAdapter.defaultBaseURL(for: kind)
            return OpenAICompatibleAdapter(kind: kind, apiKey: key, baseURL: base, session: probeSession, logger: logger)
        case .gemini:
            return GeminiContentsAdapter(apiKey: key, session: probeSession, logger: logger)
        default:
            throw HTTPError(.badRequest, message: TestError.unsupportedProvider.rawValue)
        }
    }

    private func stableCode(for error: ProviderError) -> TestError {
        switch error {
        case .creditExhausted: .creditExhausted
        case let .transient(_, status, _) where status == 429: .rateLimit
        case .transient: .upstreamError
        case .network: .network
        case .permanent: .upstreamRejected
        }
    }

    /// Minimal `max_tokens: 1` ping payload per provider. Used by /test
    /// to validate auth without burning user credits.
    static func pingPayload(for provider: ProviderID) -> [String: Any] {
        let model = switch provider {
        case .xai: "grok-4"
        case .nvidia: "meta/llama-3.1-8b-instruct"
        case .anthropic: "claude-sonnet-4-6"
        case .openai: "gpt-4o-mini"
        case .openRouter: "openrouter/auto"
        case .ollama: "llama3.1"
        case .gemini: "gemini-2.5-flash"
        case .nous: "stepfun/step-3.7-flash:free"
        }
        return [
            "model": model,
            "messages": [["role": "user", "content": "ping"]],
            "max_tokens": 1,
        ]
    }
}

/// Tiny JSON helper to keep the controller readable. Falls back to
/// empty data on failure — Hummingbird turns that into an empty body
/// which the adapter rejects with a 400 (visible failure, not silent).
private enum JSON {
    static func encode(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }
}
