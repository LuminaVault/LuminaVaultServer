import Configuration
import FluentKit
import FluentPostgresDriver
import Foundation
import Hummingbird
import HummingbirdFluent
import HummingbirdCompression
import HummingbirdWebSocket
import JWTKit
import Logging
import Metrics
import OpenAPIHummingbird
import OTel
import OTLPGRPC
import ServiceLifecycle
import Tracing

///  Build application
/// - Parameter reader: configuration reader
func buildApplication(reader: ConfigReader) async throws -> some ApplicationProtocol {
    let logger = {
        var logger = Logger(label: "LuminaVaultServer")
        logger.logLevel = reader.string(forKey: "log.level", as: Logger.Level.self, default: .info)
        return logger
    }()

    // Observability: when otel.enabled=true, bootstrap real OTLP exporters
    // wired at the docker-compose `jaeger` service (`OTEL_EXPORTER_OTLP_ENDPOINT
    // = http://jaeger:4317`). Otherwise keep no-op metrics for test runs.
    let otelEnabled = reader.string(forKey: "otel.enabled", default: "false").lowercased() == "true"
    let otelServices = otelEnabled
        ? try await bootstrapOTelOnce(serviceName: reader.string(forKey: "otel.serviceName", default: "luminavault"))
        : nil
    if !otelEnabled {
        bootstrapMetricsOnce()
    }

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
        await fluent.migrations.add(M10_CreateDeviceToken())
        await fluent.migrations.add(M11_CreateWebAuthnCredential())
        await fluent.migrations.add(M12_CreateSpace())
        await fluent.migrations.add(M13_CreateVaultFile())
        await fluent.migrations.add(M14_CreateHealthEvent())
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
        logLevel: logger.logLevel,
        appleClientID: reader.string(forKey: "oauth.apple.clientId", default: ""),
        googleClientID: reader.string(forKey: "oauth.google.clientId", default: ""),
        vaultRootPath: reader.string(forKey: "vault.rootPath", default: "/tmp/luminavault"),
        hermesGatewayKind: reader.string(forKey: "hermes.gatewayKind", default: "filesystem"),
        hermesGatewayURL: reader.string(forKey: "hermes.gatewayUrl", default: "http://hermes:8642"),
        hermesDataRoot: reader.string(forKey: "hermes.dataRoot", default: "/app/data/hermes"),
        hermesDefaultModel: reader.string(forKey: "hermes.defaultModel", default: "hermes-3"),
        webAuthnEnabled: reader.string(forKey: "webauthn.enabled", default: "false").lowercased() == "true",
        webAuthnRelyingPartyID: reader.string(forKey: "webauthn.relyingPartyId", default: ""),
        webAuthnRelyingPartyName: reader.string(forKey: "webauthn.relyingPartyName", default: "LuminaVault"),
        webAuthnRelyingPartyOrigin: reader.string(forKey: "webauthn.relyingPartyOrigin", default: ""),
        apnsEnabled: reader.string(forKey: "apns.enabled", default: "false").lowercased() == "true",
        apnsBundleID: reader.string(forKey: "apns.bundleId", default: ""),
        apnsTeamID: reader.string(forKey: "apns.teamId", default: ""),
        apnsKeyID: reader.string(forKey: "apns.keyId", default: ""),
        apnsPrivateKeyPath: reader.string(forKey: "apns.privateKeyPath", default: ""),
        apnsEnvironment: reader.string(forKey: "apns.environment", default: "development"),
        corsAllowedOrigins: reader.string(forKey: "cors.allowedOrigins", default: "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty },
        adminToken: reader.string(forKey: "admin.token", default: ""),
        xClientID: reader.string(forKey: "oauth.x.clientId", default: ""),
        smsKind: reader.string(forKey: "sms.kind", default: "logging"),
        twilioAccountSID: reader.string(forKey: "twilio.accountSid", default: ""),
        twilioAuthToken: reader.string(forKey: "twilio.authToken", default: ""),
        twilioFromNumber: reader.string(forKey: "twilio.fromNumber", default: "")
    )

    let router = try buildRouter(services: services)
    var appServices: [any Service] = fluentEnabled ? [fluent] : []
    if let otelServices {
        appServices.append(otelServices.metrics)
        appServices.append(otelServices.tracer)
    }
    let app = Application(
        router: router,
        server: .http1WebSocketUpgrade(webSocketRouter: router),
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
        TracingMiddleware()
        MetricsMiddleware()
        LogRequestsMiddleware(.info)
        OpenAPIRequestContextMiddleware()
    }
    router.middlewares.add(RequestDecompressionMiddleware())
    router.middlewares.add(ResponseCompressionMiddleware(minimumResponseSizeToCompress: 512))
    // CORS — explicit origin list in prod (`cors.allowedOrigins=https://app.x,https://web.y`).
    // Empty list falls back to `.all` (dev only). For prod, AllowedOriginsMiddleware
    // strips Origin headers that aren't on the list before CORSMiddleware echoes them.
    if services.corsAllowedOrigins.isEmpty {
        router.add(middleware: CORSMiddleware(allowOrigin: .all))
    } else {
        router.add(middleware: AllowedOriginsMiddleware<AppRequestContext>(
            allowed: Set(services.corsAllowedOrigins)
        ))
        router.add(middleware: CORSMiddleware(
            allowOrigin: .originBased,
            allowHeaders: [.contentType, .authorization],
            allowMethods: [.get, .post, .put, .delete, .options, .patch],
            allowCredentials: true,
            maxAge: .seconds(600)
        ))
    }
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
    let authTelemetry = RouteTelemetry(labelPrefix: "auth", logger: Logger(label: "lv.auth"))
    let llmTelemetry = RouteTelemetry(labelPrefix: "llm", logger: Logger(label: "lv.llm"))
    let pushService = APNSNotificationService(
        enabled: services.apnsEnabled,
        bundleID: services.apnsBundleID,
        teamID: services.apnsTeamID,
        keyID: services.apnsKeyID,
        privateKeyPath: services.apnsPrivateKeyPath,
        environment: services.apnsEnvironment,
        fluent: services.fluent,
        logger: Logger(label: "lv.apns")
    )
    let authRepo = DatabaseAuthRepository(fluent: services.fluent)
    let authService = DefaultAuthService(
        repo: authRepo,
        hasher: BcryptPasswordHasher(),
        fluent: services.fluent,
        jwtKeys: services.jwtKeys,
        jwtKID: services.jwtKID,
        mfaService: mfaService,
        resetCodeSender: resetSender,
        resetCodeGenerator: resetGen,
        hermesProfileService: hermesProfileService
    )
    let webAuthnService = WebAuthnService(
        enabled: services.webAuthnEnabled,
        relyingPartyID: services.webAuthnRelyingPartyID,
        relyingPartyName: services.webAuthnRelyingPartyName,
        relyingPartyOrigin: services.webAuthnRelyingPartyOrigin,
        fluent: services.fluent,
        repo: authRepo,
        authService: authService,
        logger: Logger(label: "lv.webauthn")
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
        rateLimitStorage: rateLimitStorage,
        telemetry: authTelemetry,
        webAuthnService: webAuthnService
    ).addRoutes(to: router)

    // Passwordless / multi-provider auth: phone OTP, email magic-link, X OAuth.
    // Pre-auth challenges live in-memory; multi-replica deployments must move
    // them onto a shared PersistDriver (Redis).
    let preAuthStore = PreAuthChallengeStore()
    let smsSender: any SMSSender = makeSMSSender(
        kind: services.smsKind,
        accountSID: services.twilioAccountSID,
        authToken: services.twilioAuthToken,
        fromNumber: services.twilioFromNumber,
        logger: Logger(label: "lv.sms")
    )
    let multiProviderGroup = router.group("/v1/auth")
    PhoneAuthController(
        authService: authService,
        smsSender: smsSender,
        generator: DefaultOTPCodeGenerator(),
        challengeStore: preAuthStore,
        logger: Logger(label: "lv.auth.phone")
    ).addRoutes(to: multiProviderGroup)
    EmailMagicLinkController(
        authService: authService,
        emailSender: LoggingEmailOTPSender(logger: Logger(label: "lv.auth.magic")),
        generator: DefaultOTPCodeGenerator(),
        challengeStore: preAuthStore,
        logger: Logger(label: "lv.auth.magic")
    ).addRoutes(to: multiProviderGroup)
    XOAuthController(
        authService: authService,
        xClient: DefaultXAPIClient(logger: Logger(label: "lv.auth.x")),
        logger: Logger(label: "lv.auth.x")
    ).addRoutes(to: multiProviderGroup)

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
    let llmController = LLMController(
        service: llmService,
        telemetry: llmTelemetry,
        notificationService: pushService
    )
    let llmGroup = router.group("/v1/llm")
        .add(middleware: jwtAuthenticator)
        .add(middleware: RateLimitMiddleware(policy: .chatByUser, storage: rateLimitStorage))
    llmController.addRoutes(to: llmGroup)

    // Memory agent (tool-calling Hermes loop) + protected routes.
    let memoryService = HermesMemoryService(
        transport: URLSessionHermesChatTransport(
            baseURL: hermesURL,
            session: .shared,
            logger: Logger(label: "lv.memory")
        ),
        memories: MemoryRepository(fluent: services.fluent),
        embeddings: DeterministicEmbeddingService(),
        defaultModel: services.hermesDefaultModel,
        logger: Logger(label: "lv.memory")
    )
    let memoryController = MemoryController(service: memoryService)
    // captureByUser covers /upsert (write capture) and /search (read agent loop);
    // both are tenant-scoped Hermes calls so the per-user budget is shared.
    let memoryGroup = router.group("/v1/memory")
        .add(middleware: jwtAuthenticator)
        .add(middleware: RateLimitMiddleware(policy: .captureByUser, storage: rateLimitStorage))
    memoryController.addRoutes(to: memoryGroup)

    // Query (natural-language semantic search) — protected.
    let queryController = QueryController(service: memoryService)
    let queryGroup = router.group("/v1/query").add(middleware: jwtAuthenticator)
    queryController.addRoutes(to: queryGroup)

    // Memo generator (read-only agent loop → markdown synthesis → vault save).
    let memoGenerator = MemoGeneratorService(
        transport: URLSessionHermesChatTransport(
            baseURL: hermesURL,
            session: .shared,
            logger: Logger(label: "lv.memo")
        ),
        memories: MemoryRepository(fluent: services.fluent),
        embeddings: DeterministicEmbeddingService(),
        vaultPaths: vaultPaths,
        fluent: services.fluent,
        defaultModel: services.hermesDefaultModel,
        logger: Logger(label: "lv.memo")
    )
    let memoController = MemoController(service: memoGenerator)
    let memoGroup = router.group("/v1/memos").add(middleware: jwtAuthenticator)
    memoController.addRoutes(to: memoGroup)

    // Vault file upload (markdown + images) — protected.
    let vaultController = VaultController(
        vaultPaths: vaultPaths,
        logger: Logger(label: "lv.vault")
    )
    let vaultGroup = router.group("/v1/vault")
        .add(middleware: jwtAuthenticator)
        .add(middleware: RateLimitMiddleware(policy: .vaultUploadByUser, storage: rateLimitStorage))
    vaultController.addRoutes(to: vaultGroup)

    // kb-compile (write batch + Hermes learning loop) — protected.
    let kbCompileService = KBCompileService(
        vaultPaths: vaultPaths,
        transport: URLSessionHermesChatTransport(
            baseURL: hermesURL,
            session: .shared,
            logger: Logger(label: "lv.kb-compile")
        ),
        memories: MemoryRepository(fluent: services.fluent),
        embeddings: DeterministicEmbeddingService(),
        defaultModel: services.hermesDefaultModel,
        logger: Logger(label: "lv.kb-compile")
    )
    let kbCompileController = KBCompileController(service: kbCompileService)
    let kbCompileGroup = router.group("/v1/kb-compile")
        .add(middleware: jwtAuthenticator)
        .add(middleware: RateLimitMiddleware(policy: .kbCompileByUser, storage: rateLimitStorage))
    kbCompileController.addRoutes(to: kbCompileGroup)

    // Spaces (user-defined organizing folders) — protected.
    let spacesService = SpacesService(
        fluent: services.fluent,
        vaultPaths: vaultPaths,
        logger: Logger(label: "lv.spaces")
    )
    let spacesController = SpacesController(service: spacesService)
    let spacesGroup = router.group("/v1/spaces").add(middleware: jwtAuthenticator)
    spacesController.addRoutes(to: spacesGroup)

    // Health ingest (HealthKit / Google Fit / manual) — protected.
    let healthController = HealthIngestController(
        fluent: services.fluent,
        logger: Logger(label: "lv.health")
    )
    let healthGroup = router.group("/v1/health").add(middleware: jwtAuthenticator)
    healthController.addRoutes(to: healthGroup)

    // Admin: hermes-profile reconciliation. Shared-secret gated; off when
    // `admin.token` is empty.
    let reconciler = HermesProfileReconciler(
        fluent: services.fluent,
        service: hermesProfileService,
        vaultPaths: vaultPaths,
        hermesDataRoot: services.hermesDataRoot,
        logger: Logger(label: "lv.admin")
    )
    let adminController = AdminController(reconciler: reconciler)
    let adminGroup = router.group("/v1/admin/hermes-profiles")
        .add(middleware: AdminTokenMiddleware<AppRequestContext>(expectedToken: services.adminToken))
    adminController.addRoutes(to: adminGroup)

    // Device tokens (APNS / FCM) — protected.
    let deviceController = DeviceController(fluent: services.fluent)
    let deviceGroup = router.group("/v1/devices").add(middleware: jwtAuthenticator)
    deviceController.addRoutes(to: deviceGroup)

    let websocketGroup = router.group("/v1/ws").add(middleware: jwtAuthenticator)
    websocketGroup.ws("") { _, context in
        guard (try? context.requireIdentity()) != nil else {
            return .dontUpgrade
        }
        return .upgrade()
    } onUpgrade: { inbound, outbound, context in
        let user = try context.requestContext.requireIdentity()
        let tenantID = try user.requireID().uuidString
        let connectionManager = ConnectionManager.shared
        let connectionID = await connectionManager.register(
            tenantID: tenantID,
            username: user.username,
            outbound: outbound
        )
        defer {
            Task {
                await connectionManager.remove(tenantID: tenantID, connectionID: connectionID)
            }
        }

        do {
            for try await packet in inbound.messages(maxSize: .max) {
                if case .text(let message) = packet {
                    await connectionManager.broadcast(tenantID: tenantID, message: message)
                }
            }
        } catch {
            context.logger.debug("websocket closed", metadata: ["error": .string("\(error)")])
        }
    }

    return router
}

/// `MetricsSystem.bootstrap` precondition-fails if called twice in the same
/// process, which kills any test runner that builds the application more
/// than once. Latch the call so the first wins and subsequent calls no-op.
private let metricsBootstrap: Void = {
    MetricsSystem.bootstrap(DiscardingMetricsFactory())
}()

private func bootstrapMetricsOnce() {
    _ = metricsBootstrap
}

/// OTel tracer + metrics-reader services that need to be added to the
/// app's `ServiceGroup` so their lifecycle is managed (start, periodic
/// export, graceful shutdown).
struct OTelServices: Sendable {
    let metrics: any Service
    let tracer: any Service
}

/// Same single-shot pattern as `bootstrapMetricsOnce` — guards against
/// multiple `buildApplication` calls in a single test process.
private actor OTelLatch {
    static let shared = OTelLatch()
    private var services: OTelServices?

    func bootstrap(serviceName: String) async throws -> OTelServices {
        if let services { return services }

        let environment = OTelEnvironment.detected()
        let resourceDetection = OTelResourceDetection(detectors: [
            OTelProcessResourceDetector(),
            OTelEnvironmentResourceDetector(environment: environment),
            .manual(OTelResource(attributes: ["service.name": "\(serviceName)"])),
        ])
        let resource = await resourceDetection.resource(environment: environment, logLevel: .info)

        let registry = OTelMetricRegistry()
        let metricsExporter = try OTLPGRPCMetricExporter(configuration: .init(environment: environment))
        let metricsReader = OTelPeriodicExportingMetricsReader(
            resource: resource,
            producer: registry,
            exporter: metricsExporter,
            configuration: .init(environment: environment, exportInterval: .seconds(60))
        )
        MetricsSystem.bootstrap(OTLPMetricsFactory(registry: registry))

        let spanExporter = try OTLPGRPCSpanExporter(configuration: .init(environment: environment))
        let spanProcessor = OTelBatchSpanProcessor(
            exporter: spanExporter,
            configuration: .init(environment: environment)
        )
        let tracer = OTelTracer(
            idGenerator: OTelRandomIDGenerator(),
            sampler: OTelConstantSampler(isOn: true),
            propagator: OTelW3CPropagator(),
            processor: spanProcessor,
            environment: environment,
            resource: resource
        )
        InstrumentationSystem.bootstrap(tracer)

        let bundle = OTelServices(metrics: metricsReader, tracer: tracer)
        services = bundle
        return bundle
    }
}

private func bootstrapOTelOnce(serviceName: String) async throws -> OTelServices {
    try await OTelLatch.shared.bootstrap(serviceName: serviceName)
}

private func makeSMSSender(
    kind: String,
    accountSID: String,
    authToken: String,
    fromNumber: String,
    logger: Logger
) -> any SMSSender {
    switch kind.lowercased() {
    case "twilio":
        return TwilioSMSSender(
            accountSID: accountSID,
            authToken: authToken,
            fromNumber: fromNumber,
            logger: logger
        )
    case "logging":
        return LoggingSMSSender(logger: logger)
    default:
        logger.warning("unknown sms.kind=\(kind); falling back to LoggingSMSSender")
        return LoggingSMSSender(logger: logger)
    }
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
