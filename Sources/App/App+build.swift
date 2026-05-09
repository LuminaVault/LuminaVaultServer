import Configuration
import FluentKit
import FluentPostgresDriver
import Foundation
import Hummingbird
import HummingbirdFluent
import JWTKit
import Logging
import OpenAPIHummingbird
import ServiceLifecycle

///  Build application
/// - Parameter reader: configuration reader
func buildApplication(reader: ConfigReader) async throws -> some ApplicationProtocol {
    let logger = {
        var logger = Logger(label: "LuminaVaultServer")
        logger.logLevel = reader.string(forKey: "log.level", as: Logger.Level.self, default: .info)
        return logger
    }()

    // --- Fluent (Postgres) — optional; tests pass fluent.enabled=false ---
    let fluentEnabledStr = reader.string(forKey: "fluent.enabled", default: "true")
    let fluentEnabled = fluentEnabledStr.lowercased() != "false"
    let fluent = Fluent(logger: logger)
    if fluentEnabled {
        fluent.databases.use(
            .postgres(configuration: .init(
                hostname: reader.string(forKey: "postgres.host", default: "127.0.0.1"),
                port: reader.int(forKey: "postgres.port", default: 5432),
                username: reader.string(forKey: "postgres.user", default: "luminavault"),
                password: reader.string(forKey: "postgres.password", default: "luminavault"),
                database: reader.string(forKey: "postgres.database", default: "luminavault"),
                tls: .disable
            )),
            as: .psql
        )
        await fluent.migrations.add(M00_EnableExtensions())
        await fluent.migrations.add(M01_CreateUser())
        await fluent.migrations.add(M02_CreateRefreshToken())
        await fluent.migrations.add(M03_CreatePasswordResetToken())
        await fluent.migrations.add(M04_CreateMFAChallenge())
        await fluent.migrations.add(M05_CreateOAuthIdentity())
        await fluent.migrations.add(M06_CreateMemory())
        await fluent.migrations.add(M07_AddMemoryEmbedding())
        await fluent.migrations.add(M08_CreateHermesProfile())
        await fluent.migrations.add(M09_AddUsernameToUser())
        let autoMigrateStr = reader.string(forKey: "fluent.autoMigrate", default: "true")
        if autoMigrateStr.lowercased() != "false" {
            try await fluent.migrate()
        }
    }

    // --- JWT keys (HMAC HS256) ---
    let jwtKeys = JWTKeyCollection()
    let secret = reader.string(forKey: "jwt.hmac.secret", default: "")
    guard !secret.isEmpty else {
        fatalError("jwt.hmac.secret must be set (env JWT_HMAC_SECRET)")
    }
    let kid = JWKIdentifier(string: reader.string(forKey: "jwt.kid", default: "lv-default"))
    await jwtKeys.add(hmac: HMACKey(stringLiteral: secret), digestAlgorithm: .sha256, kid: kid)

    let services = ServiceContainer(
        fluent: fluent,
        jwtKeys: jwtKeys,
        jwtKID: kid,
        appleClientID: reader.string(forKey: "oauth.apple.clientId", default: ""),
        googleClientID: reader.string(forKey: "oauth.google.clientId", default: ""),
        vaultRootPath: reader.string(forKey: "vault.rootPath", default: "/tmp/luminavault"),
        hermesGatewayKind: reader.string(forKey: "hermes.gatewayKind", default: "filesystem"),
        hermesGatewayURL: reader.string(forKey: "hermes.gatewayUrl", default: "http://hermes:8642"),
        hermesDataRoot: reader.string(forKey: "hermes.dataRoot", default: "/app/data/hermes"),
        hermesDefaultModel: reader.string(forKey: "hermes.defaultModel", default: "hermes-3")
    )

    let router = try buildRouter(services: services)
    let appServices: [any Service] = fluentEnabled ? [fluent] : []
    let app = Application(
        router: router,
        configuration: ApplicationConfiguration(reader: reader.scoped(to: "http")),
        services: appServices,
        logger: logger
    )
    return app
}

/// Build router
func buildRouter(services: ServiceContainer) throws -> Router<AppRequestContext> {
    let router = Router(context: AppRequestContext.self)
    router.addMiddleware {
        LogRequestsMiddleware(.info)
        OpenAPIRequestContextMiddleware()
    }
    router.middlewares.add(RequestDecompressionMiddleware())
    router.middlewares.add(ResponseCompressionMiddleware(minimumResponseSizeToCompress: 512))

    router.get("/health") { _, _ -> String in "ok" }

    // Mount OpenAPI handlers (existing surface)
    let api = APIImplementation()
    try api.registerHandlers(on: router)

    // Auth routes
    let mfaService = DefaultMFAService(
        fluent: services.fluent,
        sender: LoggingEmailOTPSender(logger: Logger(label: "lv.mfa")),
        generator: DefaultOTPCodeGenerator()
    )
    let resetSender = LoggingEmailOTPSender(logger: Logger(label: "lv.reset"))
    let resetGen = DefaultOTPCodeGenerator()
    let vaultPaths = VaultPathService(rootPath: services.vaultRootPath)
    let hermesLogger = Logger(label: "lv.hermes")
    let hermesGateway: any HermesGateway = makeHermesGateway(
        kind: services.hermesGatewayKind,
        dataRoot: services.hermesDataRoot,
        logger: hermesLogger
    )
    let hermesProfileService = HermesProfileService(
        fluent: services.fluent,
        gateway: hermesGateway,
        vaultPaths: vaultPaths
    )
    let authService = DefaultAuthService(
        repo: DatabaseAuthRepository(fluent: services.fluent),
        hasher: BcryptPasswordHasher(),
        fluent: services.fluent,
        jwtKeys: services.jwtKeys,
        jwtKID: services.jwtKID,
        mfaService: mfaService,
        resetCodeSender: resetSender,
        resetCodeGenerator: resetGen,
        hermesProfileService: hermesProfileService
    )

    var oauthProviders: [String: any OAuthProvider] = [:]
    if !services.appleClientID.isEmpty {
        oauthProviders["apple"] = AppleOAuthProvider(audience: services.appleClientID)
    }
    if !services.googleClientID.isEmpty {
        oauthProviders["google"] = GoogleOAuthProvider(audience: services.googleClientID)
    }
    let rateLimitStorage = MemoryPersistDriver()
    AuthController(
        service: authService,
        oauthProviders: oauthProviders,
        rateLimitStorage: rateLimitStorage
    ).addRoutes(to: router)

    // Protected (JWT-required) routes
    let jwtAuthenticator = JWTAuthenticator(jwtKeys: services.jwtKeys, fluent: services.fluent)
    router.group("/v1/auth")
        .add(middleware: jwtAuthenticator)
        .get("/me", use: meHandler)

    // LLM (Hermes-backed) routes — protected.
    guard let hermesURL = URL(string: services.hermesGatewayURL) else {
        fatalError("invalid hermes.gatewayUrl: \(services.hermesGatewayURL)")
    }
    let llmService = DefaultHermesLLMService(
        baseURL: hermesURL,
        session: .shared,
        defaultModel: services.hermesDefaultModel,
        logger: Logger(label: "lv.llm")
    )
    let llmController = LLMController(service: llmService)
    let llmGroup = router.group("/v1/llm").add(middleware: jwtAuthenticator)
    llmController.addRoutes(to: llmGroup)

    return router
}

private func makeHermesGateway(
    kind: String,
    dataRoot: String,
    logger: Logger
) -> any HermesGateway {
    switch kind.lowercased() {
    case "filesystem":
        return FilesystemHermesGateway(rootPath: dataRoot, logger: logger)
    case "logging":
        return LoggingHermesGateway(logger: logger)
    default:
        logger.warning("unknown hermes.gatewayKind=\(kind); falling back to LoggingHermesGateway")
        return LoggingHermesGateway(logger: logger)
    }
}

@Sendable
private func meHandler(_: Request, ctx: AppRequestContext) async throws -> MeResponse {
    let user = try ctx.requireIdentity()
    return MeResponse(
        userId: try user.requireID(),
        email: user.email,
        username: user.username,
        isVerified: user.isVerified
    )
}
