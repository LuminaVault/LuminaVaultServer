import Foundation
import Hummingbird
import Logging

/// HER-240c — HTTP surface for the Grok runtime. Mounted under `/v1/grok`
/// behind `JWTAuthenticator + PremiumGuardMiddleware`. Each handler:
///   1. Resolves the tenant's Hermes container handle (404 / 409 if no
///      container exists or the user hasn't completed xai-oauth).
///   2. Delegates to `HermesGrokProxy` for the actual HTTP call to the
///      per-tenant container's gateway.
struct GrokController {
    let containerManager: HermesContainerManager
    let proxy: HermesGrokProxy
    let logger: Logger

    /// Set true to ship the routes with TTS returning 501 (server hasn't
    /// wired an upstream TTS provider yet). Default true to match the
    /// HER-240c plan's "ship Grok features, TTS behind a flag" decision.
    let ttsDisabled: Bool

    init(
        containerManager: HermesContainerManager,
        proxy: HermesGrokProxy,
        logger: Logger,
        ttsDisabled: Bool = true,
    ) {
        self.containerManager = containerManager
        self.proxy = proxy
        self.logger = logger
        self.ttsDisabled = ttsDisabled
    }

    func addRoutes(to group: RouterGroup<AppRequestContext>) {
        group.post("/grok/chat", use: chat)
        group.post("/grok/x-search", use: xSearch)
        group.post("/grok/vision", use: vision)
        group.post("/grok/tts", use: tts)
    }

    @Sendable
    func chat(_ req: Request, ctx: AppRequestContext) async throws -> GrokChatResponse {
        let body = try await req.decode(as: GrokChatRequest.self, context: ctx)
        let handle = try await resolveHandle(ctx: ctx)
        do {
            return try await proxy.chat(handle: handle, request: body)
        } catch {
            throw mapProxyError(error)
        }
    }

    @Sendable
    func xSearch(_ req: Request, ctx: AppRequestContext) async throws -> GrokXSearchResponse {
        let body = try await req.decode(as: GrokXSearchRequest.self, context: ctx)
        guard !body.query.isEmpty else {
            throw HTTPError(.badRequest, message: "query required")
        }
        let handle = try await resolveHandle(ctx: ctx)
        do {
            return try await proxy.xSearch(handle: handle, request: body)
        } catch {
            throw mapProxyError(error)
        }
    }

    @Sendable
    func vision(_ req: Request, ctx: AppRequestContext) async throws -> GrokVisionResponse {
        let body = try await req.decode(as: GrokVisionRequest.self, context: ctx)
        guard !body.imageURLs.isEmpty else {
            throw HTTPError(.badRequest, message: "imageURLs required")
        }
        let handle = try await resolveHandle(ctx: ctx)
        do {
            return try await proxy.vision(handle: handle, request: body)
        } catch {
            throw mapProxyError(error)
        }
    }

    @Sendable
    func tts(_: Request, ctx _: AppRequestContext) async throws -> GrokTTSResponse {
        if ttsDisabled {
            throw HTTPError(.notImplemented, message: "tts_coming_soon")
        }
        // TODO: HER-240c follow-up — wire the upstream TTS provider when xAI's
        // audio endpoint goes public or LuminaVault flips an alt provider.
        throw HTTPError(.notImplemented, message: "tts_coming_soon")
    }

    // MARK: - Helpers

    private func resolveHandle(ctx: AppRequestContext) async throws -> HermesContainerHandle {
        let tenantID = try ctx.requireTenantID()
        guard let handle = try await containerManager.handle(tenantID: tenantID) else {
            // PremiumGuard let them in but no container exists yet —
            // they haven't completed the xai-oauth flow. 409 prompts the
            // iOS client to route the user back to Linked Accounts.
            throw HTTPError(.conflict, message: "xai_not_connected")
        }
        guard handle.xaiConnectedAt != nil else {
            throw HTTPError(.conflict, message: "xai_not_connected")
        }
        return handle
    }

    private func mapProxyError(_ error: any Error) -> any Error {
        if let proxyErr = error as? HermesGrokProxy.Error {
            switch proxyErr {
            case let .nonZeroStatus(code):
                logger.warning("grok proxy upstream \(code)")
                return HTTPError(.badGateway, message: "grok_upstream_\(code)")
            case .decodeFailed:
                return HTTPError(.badGateway, message: "grok_upstream_decode_failed")
            case .missingAnswer:
                return HTTPError(.badGateway, message: "grok_upstream_missing_answer")
            }
        }
        return error
    }
}
