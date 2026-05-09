import Hummingbird

struct AuthController {
    let service: any AuthService
    /// Keyed by provider name ("apple", "google"). Empty when OAuth not configured.
    let oauthProviders: [String: any OAuthProvider]

    func addRoutes(to router: Router<AppRequestContext>) {
        let group = router.group("/v1/auth")
        group.post("/register", use: register)
        group.post("/login", use: login)
        group.post("/refresh", use: refresh)
        group.post("/logout", use: logout)
        group.post("/mfa/verify", use: mfaVerify)
        group.post("/mfa/resend", use: mfaResend)
        group.post("/oauth/:provider/exchange", use: oauthExchange)
    }

    @Sendable
    func register(_ req: Request, ctx: AppRequestContext) async throws -> AuthResponse {
        let body = try await req.decode(as: RegisterRequest.self, context: ctx)
        return try await service.register(email: body.email, password: body.password)
    }

    @Sendable
    func login(_ req: Request, ctx: AppRequestContext) async throws -> AuthResponse {
        let body = try await req.decode(as: LoginRequest.self, context: ctx)
        let requireMFA = req.headers[.init("mfa-auth-v1")!]?.lowercased() == "true"
        return try await service.login(
            email: body.email,
            password: body.password,
            requireMFA: requireMFA
        )
    }

    @Sendable
    func mfaVerify(_ req: Request, ctx: AppRequestContext) async throws -> AuthResponse {
        let body = try await req.decode(as: MFAVerifyRequest.self, context: ctx)
        return try await service.verifyMFA(challengeID: body.challengeId, code: body.code)
    }

    @Sendable
    func mfaResend(_ req: Request, ctx: AppRequestContext) async throws -> Response {
        let body = try await req.decode(as: MFAResendRequest.self, context: ctx)
        try await service.resendMFA(email: body.email)
        return Response(status: .accepted)
    }

    @Sendable
    func refresh(_ req: Request, ctx: AppRequestContext) async throws -> AuthResponse {
        let body = try await req.decode(as: RefreshRequest.self, context: ctx)
        return try await service.refresh(refreshToken: body.refreshToken)
    }

    @Sendable
    func logout(_ req: Request, ctx: AppRequestContext) async throws -> Response {
        let body = try await req.decode(as: RefreshRequest.self, context: ctx)
        try await service.revokeRefresh(refreshToken: body.refreshToken)
        return Response(status: .noContent)
    }

    @Sendable
    func oauthExchange(_ req: Request, ctx: AppRequestContext) async throws -> AuthResponse {
        guard let providerName = ctx.parameters.get("provider") else {
            throw HTTPError(.badRequest, message: "missing provider")
        }
        guard let provider = oauthProviders[providerName] else {
            throw HTTPError(.notFound, message: "unsupported provider")
        }
        let body = try await req.decode(as: OAuthExchangeRequest.self, context: ctx)
        do {
            return try await service.exchangeOAuth(provider: provider, idToken: body.idToken)
        } catch is OAuthError {
            throw HTTPError(.unauthorized, message: "invalid id_token")
        }
    }
}
