import Configuration
import FluentKit
import FluentPostgresDriver
import Foundation
import Hummingbird
import HummingbirdCompression
import HummingbirdFluent
import HummingbirdWebSocket
import JWTKit
import Logging
import LuminaVaultShared
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
                tls: .disable,
            )),
            as: .psql,
        )
        await registerMigrations(on: fluent)
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
        revenuecatWebhookSecret: reader.string(forKey: "revenuecat.webhookSecret", default: ""),
        usageFreeMtokDaily: reader.double(forKey: "usage.freeMtokDaily", default: 1.0),
        usagePerSkillMtokDaily: reader.double(forKey: "usage.perSkillMtokDaily", default: 0.2),
        usageDegradeModel: reader.string(forKey: "usage.degradeModel", default: "hermes-3-small"),
        corsAllowedOrigins: reader.string(forKey: "cors.allowedOrigins", default: "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty },
        adminToken: reader.string(forKey: "admin.token", default: ""),
        billingEnforcementEnabled: reader.string(forKey: "billing.enforcementEnabled", default: "false").lowercased() == "true",
        billingColdStoragePath: reader.string(
            forKey: "billing.coldStoragePath",
            default: URL(fileURLWithPath: reader.string(forKey: "vault.rootPath", default: "/tmp/luminavault"))
                .appendingPathComponent("cold-storage")
                .path,
        ),
        xClientID: reader.string(forKey: "oauth.x.clientId", default: ""),
        rateLimitStorageKind: reader.string(forKey: "rateLimit.storageKind", default: "memory"),
        smsKind: reader.string(forKey: "sms.kind", default: "logging"),
        twilioAccountSID: reader.string(forKey: "twilio.accountSid", default: ""),
        twilioAuthToken: reader.string(forKey: "twilio.authToken", default: ""),
        twilioFromNumber: reader.string(forKey: "twilio.fromNumber", default: ""),
        phoneFixedOTP: reader.string(forKey: "phone.fixedOtp", default: ""),
        magicLinkFixedOTP: reader.string(forKey: "magic.fixedOtp", default: ""),
        geminiAPIKey: reader.string(forKey: "gemini.apiKey", default: ""),
        ttsProvider: reader.string(forKey: "tts.provider", default: "openai"),
        ttsDefaultModel: reader.string(forKey: "tts.defaultModel", default: "tts-1"),
        ttsCharactersDaily: Int64(reader.int(forKey: "tts.charactersDaily", default: 1_000_000)),
    )

    var appServices: [any Service] = fluentEnabled ? [fluent] : []
    let router = try buildRouter(reader: reader, services: services, managedServices: &appServices)
    if fluentEnabled {
        let lapseArchiver = LapseArchiverJob(
            fluent: fluent,
            vaultPaths: VaultPathService(rootPath: services.vaultRootPath),
            coldStoragePath: services.billingColdStoragePath,
            logger: Logger(label: "lv.billing.lapse-archiver"),
        )
        appServices.append(LapseArchiverService(
            job: lapseArchiver,
            logger: Logger(label: "lv.billing.lapse-archiver"),
        ))
    }
    if let otelServices {
        appServices.append(otelServices.metrics)
        appServices.append(otelServices.tracer)
    }
    return Application(
        router: router,
        server: .http1WebSocketUpgrade(webSocketRouter: router),
        configuration: ApplicationConfiguration(reader: reader.scoped(to: "http")),
        services: appServices,
        logger: logger,
    )
}

/// Build router
func buildRouter(services: ServiceContainer, reader: ConfigReader) throws -> Router<AppRequestContext> {
    var managedServices: [any Service] = []
    return try buildRouter(reader: reader, services: services, managedServices: &managedServices)
}

/// Build router and surface any ServiceLifecycle-managed background services
/// constructed alongside route dependencies.
/// HER-200 M2 — god function. Extract `buildAuthRoutes`, `buildSkillRoutes`,
/// `buildMemoryRoutes`, `buildAdminRoutes`, `buildLLMRoutes`. Pure refactor,
/// keep semantics identical. Largest maintenance liability in the repo.
func buildRouter(
    reader: ConfigReader,
    services: ServiceContainer,
    managedServices: inout [any Service],
) throws -> Router<AppRequestContext> {
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
            allowed: Set(services.corsAllowedOrigins),
        ))
        router.add(middleware: CORSMiddleware(
            allowOrigin: .originBased,
            allowHeaders: [.contentType, .authorization],
            allowMethods: [.get, .post, .put, .delete, .options, .patch],
            allowCredentials: true,
            maxAge: .seconds(600),
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
        generator: DefaultOTPCodeGenerator(),
    )
    let resetSender = LoggingEmailOTPSender(logger: Logger(label: "lv.reset"))
    let resetGen = DefaultOTPCodeGenerator()
    let verifySender = LoggingEmailOTPSender(logger: Logger(label: "lv.verify"))
    let verifyGen = DefaultOTPCodeGenerator()
    let vaultPaths = VaultPathService(rootPath: services.vaultRootPath)
    let hermesLogger = Logger(label: "lv.hermes")
    let hermesGateway: any HermesGateway = makeHermesGateway(
        kind: services.hermesGatewayKind,
        dataRoot: services.hermesDataRoot,
        logger: hermesLogger,
    )
    let hermesProfileService = HermesProfileService(
        fluent: services.fluent,
        gateway: hermesGateway,
        vaultPaths: vaultPaths,
    )
    let authTelemetry = RouteTelemetry(labelPrefix: "auth", logger: Logger(label: "lv.auth"))
    let llmTelemetry = RouteTelemetry(labelPrefix: "llm", logger: Logger(label: "lv.llm"))
    let soulTelemetry = RouteTelemetry(labelPrefix: "soul", logger: Logger(label: "lv.soul"))
    let pushService = APNSNotificationService(
        enabled: services.apnsEnabled,
        bundleID: services.apnsBundleID,
        teamID: services.apnsTeamID,
        keyID: services.apnsKeyID,
        privateKeyPath: services.apnsPrivateKeyPath,
        environment: services.apnsEnvironment,
        fluent: services.fluent,
        logger: Logger(label: "lv.apns"),
    )
    // HER-196 — usage-driven achievement progress + per-unlock APNS push.
    // Constructed once and threaded into every controller hot-path (Memory,
    // LLM, KBCompile, Query, Vault, SOUL) plus the read-only catalog
    // endpoints under /v1/achievements.
    let achievementsService = AchievementsService(
        fluent: services.fluent,
        pushService: pushService,
        logger: Logger(label: "lv.achievements"),
    )
    let authRepo = DatabaseAuthRepository(fluent: services.fluent)
    let soulService = SOULService(
        vaultPaths: vaultPaths,
        hermesDataRoot: services.hermesDataRoot,
        logger: Logger(label: "lv.soul"),
    )
    let authService = DefaultAuthService(
        repo: authRepo,
        hasher: BcryptPasswordHasher(),
        fluent: services.fluent,
        jwtKeys: services.jwtKeys,
        jwtKID: services.jwtKID,
        mfaService: mfaService,
        resetCodeSender: resetSender,
        resetCodeGenerator: resetGen,
        verificationCodeSender: verifySender,
        verificationCodeGenerator: verifyGen,
        hermesProfileService: hermesProfileService,
        soulService: soulService,
        logger: Logger(label: "lv.auth"),
    )
    let webAuthnService = WebAuthnService(
        enabled: services.webAuthnEnabled,
        relyingPartyID: services.webAuthnRelyingPartyID,
        relyingPartyName: services.webAuthnRelyingPartyName,
        relyingPartyOrigin: services.webAuthnRelyingPartyOrigin,
        fluent: services.fluent,
        repo: authRepo,
        authService: authService,
        logger: Logger(label: "lv.webauthn"),
    )

    var oauthProviders: [String: any OAuthProvider] = [:]
    if !services.appleClientID.isEmpty {
        oauthProviders["apple"] = AppleOAuthProvider(audience: services.appleClientID)
    }
    if !services.googleClientID.isEmpty {
        oauthProviders["google"] = GoogleOAuthProvider(audience: services.googleClientID)
    }
    // HER-200 M3 — single config key controls rate-limit storage. Memory
    // is fine for single-process; Redis seam reserved for multi-replica.
    let rateLimitStorage = makeRateLimitStorage(
        kind: services.rateLimitStorageKind,
        logger: Logger(label: "lv.ratelimit"),
    )
    AuthController(
        service: authService,
        oauthProviders: oauthProviders,
        rateLimitStorage: rateLimitStorage,
        telemetry: authTelemetry,
        webAuthnService: webAuthnService,
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
        logger: Logger(label: "lv.sms"),
    )
    let multiProviderGroup = router.group("/v1/auth")
    // PhoneAuthController owns its own group wiring (per-route rate-limit
    // middlewares would otherwise leak onto sibling routes in multiProviderGroup).
    let phoneOTPGenerator: any OTPCodeGenerator = services.phoneFixedOTP.isEmpty
        ? DefaultOTPCodeGenerator()
        : FixedOTPCodeGenerator(code: services.phoneFixedOTP)
    PhoneAuthController(
        authService: authService,
        smsSender: smsSender,
        generator: phoneOTPGenerator,
        challengeStore: preAuthStore,
        rateLimitStorage: rateLimitStorage,
        logger: Logger(label: "lv.auth.phone"),
    ).addRoutes(to: router)
    let magicLinkOTPGenerator: any OTPCodeGenerator = services.magicLinkFixedOTP.isEmpty
        ? DefaultOTPCodeGenerator()
        : FixedOTPCodeGenerator(code: services.magicLinkFixedOTP)
    EmailMagicLinkController(
        authService: authService,
        emailSender: LoggingEmailOTPSender(logger: Logger(label: "lv.auth.magic")),
        generator: magicLinkOTPGenerator,
        challengeStore: preAuthStore,
        rateLimitStorage: rateLimitStorage,
        logger: Logger(label: "lv.auth.magic"),
    ).addRoutes(to: router)
    XOAuthController(
        authService: authService,
        xClient: DefaultXAPIClient(logger: Logger(label: "lv.auth.x")),
        logger: Logger(label: "lv.auth.x"),
    ).addRoutes(to: multiProviderGroup)

    // Protected (JWT-required) routes
    let jwtAuthenticator = JWTAuthenticator(jwtKeys: services.jwtKeys, fluent: services.fluent)
    let meGroup = router.group("/v1/auth")
        .add(middleware: jwtAuthenticator)
    meGroup.get("/me", use: meHandler)
    meGroup.put("/me/privacy", use: updatePrivacyHandler(fluent: services.fluent))
    meGroup.get("/me/billing", use: meBillingHandler(enforcementEnabled: services.billingEnforcementEnabled))

    let billingGroup = router.group("/v1/billing")
    RevenueCatWebhookController(
        fluent: services.fluent,
        webhookSecret: services.revenuecatWebhookSecret,
        logger: Logger(label: "lv.billing.revenuecat-webhook"),
    ).addRoutes(to: billingGroup)

    // HER-172 — SkillCatalog needs to be in scope for the ContextRouter
    // middleware on `/v1/llm` below; the full Skills runtime (runner,
    // event bus, cron) is constructed further down. SkillCatalog itself
    // has no dependencies on those, so hoisting it is safe.
    let skillsLogger = Logger(label: "lv.skills")
    let skillCatalog = SkillCatalog(vaultPaths: vaultPaths, logger: skillsLogger)
    // HER-171 — EventBus is constructed up here (alongside SkillCatalog) so
    // every publisher (vault, health, memory) and the SkillRunner subscriber
    // share the same instance. Publishers fire-and-forget; the bus is an
    // in-process actor with a bounded per-subscriber buffer.
    let eventBus = EventBus(logger: skillsLogger)

    // LLM (Hermes-backed) routes — protected.
    guard let hermesURL = URL(string: services.hermesGatewayURL) else {
        fatalError("invalid hermes.gatewayUrl: \(services.hermesGatewayURL)")
    }

    // HER-217 / HER-223 — BYO Hermes endpoint config + resolver.
    // Constructed only when `LV_SECRET_MASTER_KEY` is set so tests that
    // don't exercise BYO Hermes leave the env unset and the routes 404.
    // When unset, every chat call falls through to the managed Hermes
    // default — identical to pre-BYO behaviour.
    let byoHermesLogger = Logger(label: "lv.byo-hermes")
    let secretMasterKey = reader.string(forKey: "secret.masterKey", default: "")
    let lvEnvironment = reader.string(forKey: "lv.environment", default: "dev")
    let byoHermesAllowPrivate = reader.string(forKey: "byoHermes.allowPrivate", default: "false")
        .lowercased() == "true"
    var byoHermesController: HermesConfigController?
    var byoHermesMiddleware: HermesResolutionMiddleware?
    if !secretMasterKey.isEmpty {
        do {
            let secretBox = try SecretBox(masterKeyBase64: secretMasterKey)
            let ssrfGuard = SSRFGuard(
                allowPrivateRanges: byoHermesAllowPrivate,
                environment: lvEnvironment,
            )
            byoHermesController = HermesConfigController(
                fluent: services.fluent,
                secretBox: secretBox,
                ssrfGuard: ssrfGuard,
                logger: byoHermesLogger,
            )
            let resolver = HermesEndpointResolver(
                fluent: services.fluent,
                secretBox: secretBox,
                ssrfGuard: ssrfGuard,
                defaultBaseURL: hermesURL,
                logger: byoHermesLogger,
            )
            byoHermesMiddleware = HermesResolutionMiddleware(
                resolver: resolver,
                logger: byoHermesLogger,
            )
        } catch {
            fatalError("LV_SECRET_MASTER_KEY malformed (must be 32 bytes base64): \(error)")
        }
    } else {
        byoHermesLogger.warning(
            "BYO Hermes disabled — set LV_SECRET_MASTER_KEY to enable /v1/settings/hermes",
        )
    }

    // HER-165 routing — single shared registry + router + transport
    // injected into every chat-using service. Today the registry holds
    // only the Hermes adapter and the router always picks `hermesGateway`,
    // so the runtime behaviour is identical to the previous direct path;
    // adding `together` / `groq` / `openRouter` etc. is a registration
    // line each (HER-162..HER-164).
    let routingLogger = Logger(label: "lv.routing")
    var providerAdapters: [any ProviderAdapter] = [
        HermesGatewayAdapter(
            baseURL: hermesURL,
            session: .shared,
            logger: routingLogger,
        ),
    ]
    // HER-199 — register Gemini provider when API key is configured.
    if !services.geminiAPIKey.isEmpty {
        providerAdapters.append(GeminiContentsAdapter(
            apiKey: services.geminiAPIKey,
            session: .shared,
            logger: routingLogger,
        ))
    }
    // HER-161 — env-loaded provider registry. Reads
    // `llm.provider.<key>.apiKey` / `.baseURL` for anthropic, openai,
    // gemini, together, groq, fireworks, deepseekDirect — missing keys
    // disable that provider rather than crashing the boot. Registered
    // as a `Service` so `ServiceGroup` retains it for the app lifetime.
    let providerRegistry = ProviderRegistry.from(
        reader: reader,
        adapters: providerAdapters,
        logger: routingLogger,
    )
    managedServices.append(providerRegistry)
    // HER-161 — capability-tier table router. Picks `(provider, model)`
    // from a static matrix keyed on `(tier, capability)`, honors the
    // user's `privacy_no_cn_origin` flag, and always falls back to the
    // Hermes gateway when no upstream is enabled.
    let modelRouter: any ModelRouter = TableModelRouter(
        registry: providerRegistry,
        hermesDefaultModel: services.hermesDefaultModel,
    )
    let usageMeterService = UsageMeterService(
        fluent: services.fluent,
        freeMtokDaily: services.usageFreeMtokDaily,
        perSkillMtokDaily: services.usagePerSkillMtokDaily,
        degradeModel: services.usageDegradeModel,
        logger: Logger(label: "lv.usage-meter"),
    )

    let routedTransport = RoutedLLMTransport(
        registry: providerRegistry,
        router: modelRouter,
        logger: routingLogger,
        usageMeter: usageMeterService,
    )

    // HER-200 — use the routed transport for the user-facing chat
    // endpoint so model-based routing + failover apply to LLM calls.
    let llmService = RoutedHermesLLMService(
        transport: routedTransport,
        defaultModel: services.hermesDefaultModel,
        logger: Logger(label: "lv.llm"),
    )
    let llmController = LLMController(
        service: llmService,
        telemetry: llmTelemetry,
        notificationService: pushService,
        achievements: achievementsService,
        usageMeter: usageMeterService,
    )
    // HER-172 ContextRouter — feature-gated by `users.context_routing`.
    // Constructed unconditionally; the middleware short-circuits when the
    // flag is false OR the entitlement check fails, so wiring it here
    // does not affect Free/Trial users in any way.
    let contextRouterSelectorFactory: @Sendable (UUID, String) -> any ContextRouterSelector = { _, username in
        DefaultContextRouterSelector(
            transport: routedTransport,
            model: services.hermesDefaultModel,
            profileUsername: username,
            logger: Logger(label: "lv.context-router"),
        )
    }
    let contextRouterMiddleware = ContextRouterMiddleware(
        catalog: skillCatalog,
        selectorFactory: contextRouterSelectorFactory,
        entitlement: { user in
            EntitlementChecker.entitled(
                tier: UserTier(rawValue: user.tier) ?? .trial,
                override: TierOverride(rawValue: user.tierOverride) ?? .none,
                for: .privacyContextRouter,
            )
        },
        logger: Logger(label: "lv.context-router"),
    )

    // HER-223 — BYO Hermes resolution middleware threads the per-tenant
    // `Resolution` into `LLMRoutingContext.currentResolution`, which
    // `HermesGatewayAdapter` reads to dispatch chat traffic against the
    // user's hosted gateway. Attached to every Hermes-touching route
    // group (llm/memory/query/memos/kb-compile). When `byoHermesMiddleware`
    // is nil (LV_SECRET_MASTER_KEY unset) every chat call routes to the
    // managed Hermes default — identical to pre-BYO behaviour.
    let llmGroupBase = router.group("/v1/llm").add(middleware: jwtAuthenticator)
    let llmGroupWithByo = byoHermesMiddleware.map { llmGroupBase.add(middleware: $0) } ?? llmGroupBase
    let llmGroup = llmGroupWithByo
        .add(middleware: EntitlementMiddleware(requires: .chat, enforcementEnabled: services.billingEnforcementEnabled))
        .add(middleware: RateLimitMiddleware(policy: .chatByUser, storage: rateLimitStorage))
        .add(middleware: contextRouterMiddleware)
    llmController.addRoutes(to: llmGroup)

    // HER-203 — STT (speech-to-text) endpoint. Single configured provider
    // per boot (`transcribe.provider`, default `groq`). Registry stays
    // separate from the chat-routing `ProviderRegistry` so STT failover
    // policy can evolve independently. Adapters register only when the
    // provider's apiKey is set; with none configured the route mounts
    // and returns 503 via the service layer.
    let transcribeLogger = Logger(label: "lv.transcribe")
    var transcribeAdapters: [any TranscribeProviderAdapter] = []
    let groqAPIKey = reader.string(forKey: "transcribe.provider.groq.apiKey", isSecret: true, default: "")
    if !groqAPIKey.isEmpty {
        let groqBaseRaw = reader.string(forKey: "transcribe.provider.groq.baseURL", default: "https://api.groq.com")
        let groqBase = URL(string: groqBaseRaw) ?? URL(string: "https://api.groq.com")!
        let groqModel = reader.string(forKey: "transcribe.provider.groq.model", default: "whisper-large-v3")
        transcribeAdapters.append(GroqWhisperAdapter(
            apiKey: groqAPIKey,
            baseURL: groqBase,
            model: groqModel,
            session: .shared,
            logger: transcribeLogger,
        ))
    }
    // Test-only stub adapter — selected exclusively via
    // `transcribe.provider=stub`. The branch is unreachable in prod
    // unless someone sets that env var; the adapter has no network I/O.
    let transcribeProviderName = reader.string(forKey: "transcribe.provider", default: "groq")
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
    if transcribeProviderName == "stub" {
        transcribeAdapters.append(StubTranscribeAdapter(
            text: reader.string(forKey: "transcribe.stub.text", default: "stub transcript"),
            language: reader.string(forKey: "transcribe.stub.language", default: "en"),
            confidence: reader.double(forKey: "transcribe.stub.confidence", default: 0.95),
            durationSeconds: reader.double(forKey: "transcribe.stub.durationSeconds", default: 30),
        ))
    }
    let transcribeRegistry = TranscribeProviderRegistry.from(
        reader: reader,
        adapters: transcribeAdapters,
        logger: transcribeLogger,
    )
    managedServices.append(transcribeRegistry)
    let transcribeService = TranscribeService(
        registry: transcribeRegistry,
        usageMeter: usageMeterService,
        logger: transcribeLogger,
    )
    let transcribeController = TranscribeController(
        service: transcribeService,
        logger: transcribeLogger,
    )
    let transcribeGroup = router.group("/v1/transcribe")
        .add(middleware: jwtAuthenticator)
        .add(middleware: EntitlementMiddleware(requires: .chat, enforcementEnabled: services.billingEnforcementEnabled))
        .add(middleware: RateLimitMiddleware(policy: .transcribeByUserPerMinute, storage: rateLimitStorage))
        .add(middleware: RateLimitMiddleware(policy: .transcribeByUserDaily, storage: rateLimitStorage))
    transcribeController.addRoutes(to: transcribeGroup)

    // HER-205 — POST /v1/vision/embed. Image embedding endpoint that
    // returns a 1536-dim vector compatible with `memories.embedding`.
    // Single configured provider per boot (`vision.embed.provider`,
    // default `cohere`). Provider registers only when its apiKey is
    // non-empty; with none configured the service returns 503.
    let visionEmbedLogger = Logger(label: "lv.vision.embed")
    var visionEmbedAdapters: [any VisionEmbedProviderAdapter] = []
    let cohereVisionAPIKey = reader.string(forKey: "vision.embed.provider.cohere.apiKey", isSecret: true, default: "")
    if !cohereVisionAPIKey.isEmpty {
        let cohereBaseRaw = reader.string(forKey: "vision.embed.provider.cohere.baseURL", default: "https://api.cohere.com")
        let cohereBase = URL(string: cohereBaseRaw) ?? URL(string: "https://api.cohere.com")!
        let cohereModel = reader.string(forKey: "vision.embed.provider.cohere.model", default: "embed-image-v3.0")
        visionEmbedAdapters.append(CohereImageEmbedAdapter(
            apiKey: cohereVisionAPIKey,
            baseURL: cohereBase,
            model: cohereModel,
            session: .shared,
            logger: visionEmbedLogger,
        ))
    }
    // Test-only stub — selected exclusively via `vision.embed.provider=stub`.
    let visionEmbedProviderName = reader.string(forKey: "vision.embed.provider", default: "cohere")
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
    if visionEmbedProviderName == "stub" {
        visionEmbedAdapters.append(StubVisionEmbedAdapter(
            dim: reader.int(forKey: "vision.embed.stub.dim", default: 1024),
            fill: Float(reader.double(forKey: "vision.embed.stub.fill", default: 0.1)),
            model: reader.string(forKey: "vision.embed.stub.model", default: "stub-clip"),
            sourceWidth: reader.int(forKey: "vision.embed.stub.sourceWidth", default: 768),
            sourceHeight: reader.int(forKey: "vision.embed.stub.sourceHeight", default: 768),
        ))
    }
    let visionEmbedRegistry = VisionEmbedProviderRegistry.from(
        reader: reader,
        adapters: visionEmbedAdapters,
        logger: visionEmbedLogger,
    )
    managedServices.append(visionEmbedRegistry)
    let visionEmbedService = VisionEmbedService(
        registry: visionEmbedRegistry,
        fluent: services.fluent,
        usageMeter: usageMeterService,
        logger: visionEmbedLogger,
        // Pinned to the `memories.embedding` column width (1536, M07).
        targetDim: 1536,
    )
    let visionEmbedController = VisionEmbedController(
        service: visionEmbedService,
        logger: visionEmbedLogger,
    )
    let visionEmbedGroup = router.group("/v1/vision")
        .add(middleware: jwtAuthenticator)
        .add(middleware: EntitlementMiddleware(requires: .memoryQuery, enforcementEnabled: services.billingEnforcementEnabled))
        .add(middleware: RateLimitMiddleware(policy: .visionEmbedByUserPerMinute, storage: rateLimitStorage))
        .add(middleware: RateLimitMiddleware(policy: .visionEmbedByUserDaily, storage: rateLimitStorage))
    visionEmbedController.addRoutes(to: visionEmbedGroup)

    // HER-204 — POST /v1/tts. OpenAI-only adapter at MVP. Provider key
    // sourced from the same `llm.provider.openai.apiKey` slot already
    // loaded for chat. Empty key disables the route at construction time
    // (the controller is never wired) rather than crashing the boot.
    let openaiAPIKey = reader.string(forKey: "llm.provider.openai.apiKey", isSecret: true, default: "")
    if !openaiAPIKey.isEmpty {
        let openaiBaseURLRaw = reader.string(forKey: "llm.provider.openai.baseURL", default: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let openaiBaseURL = openaiBaseURLRaw.isEmpty
            ? URL(string: "https://api.openai.com")!
            : (URL(string: openaiBaseURLRaw) ?? URL(string: "https://api.openai.com")!)
        let ttsAdapter = OpenAITTSAdapter(
            apiKey: openaiAPIKey,
            baseURL: openaiBaseURL,
            defaultModel: services.ttsDefaultModel,
            logger: Logger(label: "lv.tts.openai"),
        )
        let routedTTSTransport = RoutedTTSTransport(
            adapter: ttsAdapter,
            defaultModel: services.ttsDefaultModel,
            logger: Logger(label: "lv.tts"),
            usageMeter: usageMeterService,
        )
        let ttsController = TTSController(
            transport: routedTTSTransport,
            telemetry: RouteTelemetry(labelPrefix: "tts", logger: Logger(label: "lv.tts")),
            logger: Logger(label: "lv.tts"),
        )
        let ttsGroup = router.group("/v1/tts")
            .add(middleware: jwtAuthenticator)
            .add(middleware: EntitlementMiddleware(requires: .chat, enforcementEnabled: services.billingEnforcementEnabled))
            .add(middleware: RateLimitMiddleware(policy: .ttsByUserPerMinute, storage: rateLimitStorage))
            .add(middleware: RateLimitMiddleware(policy: .ttsByUserDaily, storage: rateLimitStorage))
        ttsController.addRoutes(to: ttsGroup)
    } else {
        routingLogger.warning("tts disabled: llm.provider.openai.apiKey is empty")
    }

    // Memory agent (tool-calling Hermes loop) + protected routes.
    let memoryService = HermesMemoryService(
        transport: routedTransport,
        memories: MemoryRepository(fluent: services.fluent),
        embeddings: DeterministicEmbeddingService(),
        defaultModel: services.hermesDefaultModel,
        eventBus: eventBus,
        logger: Logger(label: "lv.memory"),
    )
    let memoryController = MemoryController(
        service: memoryService,
        repository: MemoryRepository(fluent: services.fluent),
        embeddings: DeterministicEmbeddingService(),
        achievements: achievementsService,
    )
    // HER-223 — memory routes also fire chat calls (memory agent loop in
    // HermesMemoryService); attach the resolution middleware so user-
    // configured gateways receive that traffic too.
    let memoryCaptureBase = router.group("/v1/memory").add(middleware: jwtAuthenticator)
    let memoryCaptureWithByo = byoHermesMiddleware.map { memoryCaptureBase.add(middleware: $0) } ?? memoryCaptureBase
    let memoryCaptureGroup = memoryCaptureWithByo
        .add(middleware: EntitlementMiddleware(requires: .capture, enforcementEnabled: services.billingEnforcementEnabled))
        .add(middleware: RateLimitMiddleware(policy: .captureByUser, storage: rateLimitStorage))
    memoryController.addCaptureRoutes(to: memoryCaptureGroup)
    let memorySearchBase = router.group("/v1/memory").add(middleware: jwtAuthenticator)
    let memorySearchWithByo = byoHermesMiddleware.map { memorySearchBase.add(middleware: $0) } ?? memorySearchBase
    let memorySearchGroup = memorySearchWithByo
        .add(middleware: EntitlementMiddleware(requires: .memoryQuery, enforcementEnabled: services.billingEnforcementEnabled))
        .add(middleware: RateLimitMiddleware(policy: .captureByUser, storage: rateLimitStorage))
    memoryController.addSearchRoutes(to: memorySearchGroup)
    // Read routes don't fire chat — skip BYO middleware to keep the
    // chain minimal.
    let memoryReadGroup = router.group("/v1/memory")
        .add(middleware: jwtAuthenticator)
    memoryController.addReadRoutes(to: memoryReadGroup)

    // HER-149: URL capture with async enrichment (YouTube oEmbed, X scraper, GenericOG).
    let urlEnrichmentService = URLEnrichmentService(
        vaultPaths: vaultPaths,
        fluent: services.fluent,
        logger: Logger(label: "lv.capture"),
    )
    let captureController = CaptureController(
        vaultPaths: vaultPaths,
        fluent: services.fluent,
        eventBus: eventBus,
        achievements: achievementsService,
        enrichmentService: urlEnrichmentService,
        logger: Logger(label: "lv.capture"),
    )
    let captureGroup = router.group("/v1/capture")
        .add(middleware: jwtAuthenticator)
        .add(middleware: EntitlementMiddleware(requires: .capture, enforcementEnabled: services.billingEnforcementEnabled))
        .add(middleware: RateLimitMiddleware(policy: .captureByUser, storage: rateLimitStorage))
    captureController.addRoutes(to: captureGroup)

    // Query (natural-language semantic search) — protected.
    let queryController = QueryController(service: memoryService, achievements: achievementsService)
    // HER-223 — query fires Hermes calls under the hood via memoryService.
    let queryBase = router.group("/v1/query").add(middleware: jwtAuthenticator)
    let queryWithByo = byoHermesMiddleware.map { queryBase.add(middleware: $0) } ?? queryBase
    let queryGroup = queryWithByo
        .add(middleware: EntitlementMiddleware(requires: .memoryQuery, enforcementEnabled: services.billingEnforcementEnabled))
    queryController.addRoutes(to: queryGroup)

    // Memo generator (read-only agent loop → markdown synthesis → vault save).
    let memoGenerator = MemoGeneratorService(
        transport: routedTransport,
        memories: MemoryRepository(fluent: services.fluent),
        embeddings: DeterministicEmbeddingService(),
        vaultPaths: vaultPaths,
        fluent: services.fluent,
        defaultModel: services.hermesDefaultModel,
        logger: Logger(label: "lv.memo"),
    )
    let memoController = MemoController(service: memoGenerator)
    // HER-223 — memo generator runs an agent loop with multiple Hermes calls.
    let memoBase = router.group("/v1/memos").add(middleware: jwtAuthenticator)
    let memoWithByo = byoHermesMiddleware.map { memoBase.add(middleware: $0) } ?? memoBase
    let memoGroup = memoWithByo
        .add(middleware: EntitlementMiddleware(requires: .memoGenerator, enforcementEnabled: services.billingEnforcementEnabled))
    memoController.addRoutes(to: memoGroup)

    // Vault file upload (markdown + images) — protected.
    let vaultController = VaultController(
        vaultPaths: vaultPaths,
        fluent: services.fluent,
        eventBus: eventBus,
        achievements: achievementsService,
        logger: Logger(label: "lv.vault"),
    )
    let vaultGroup = router.group("/v1/vault")
        .add(middleware: jwtAuthenticator)
        .add(middleware: RateLimitMiddleware(policy: .vaultUploadByUser, storage: rateLimitStorage))
    vaultController.addRoutes(to: vaultGroup)

    // HER-91: vault export — separate group so the heavier per-user limit
    // doesn't fight the upload limiter, and so exports never burn the
    // upload bucket.
    let vaultExportGroup = router.group("/v1/vault")
        .add(middleware: jwtAuthenticator)
        .add(middleware: RateLimitMiddleware(policy: .vaultExportByUser, storage: rateLimitStorage))
    vaultController.addExportRoute(to: vaultExportGroup)

    // kb-compile (write batch + Hermes learning loop) — protected.
    let kbCompileService = KBCompileService(
        vaultPaths: vaultPaths,
        transport: routedTransport,
        memories: MemoryRepository(fluent: services.fluent),
        embeddings: DeterministicEmbeddingService(),
        defaultModel: services.hermesDefaultModel,
        logger: Logger(label: "lv.kb-compile"),
    )
    let kbCompileController = KBCompileController(service: kbCompileService, achievements: achievementsService)
    // HER-223 — kb-compile fires the heaviest Hermes traffic; must route
    // to the user's gateway when one is configured.
    let kbCompileBase = router.group("/v1/kb-compile").add(middleware: jwtAuthenticator)
    let kbCompileWithByo = byoHermesMiddleware.map { kbCompileBase.add(middleware: $0) } ?? kbCompileBase
    let kbCompileGroup = kbCompileWithByo
        .add(middleware: EntitlementMiddleware(requires: .kbCompile, enforcementEnabled: services.billingEnforcementEnabled))
        .add(middleware: RateLimitMiddleware(policy: .kbCompileByUser, storage: rateLimitStorage))
    kbCompileController.addRoutes(to: kbCompileGroup)

    // Spaces (user-defined organizing folders) — protected.
    let spacesService = SpacesService(
        fluent: services.fluent,
        vaultPaths: vaultPaths,
        logger: Logger(label: "lv.spaces"),
    )
    let spacesController = SpacesController(service: spacesService)
    let spacesGroup = router.group("/v1/spaces").add(middleware: jwtAuthenticator)
    spacesController.addRoutes(to: spacesGroup)

    // SOUL.md CRUD (HER-85) — protected; per-user rate limited.
    let soulController = SoulController(service: soulService, telemetry: soulTelemetry, achievements: achievementsService)
    let soulGroup = router.group("/v1/soul")
        .add(middleware: jwtAuthenticator)
        .add(middleware: RateLimitMiddleware(policy: .soulByUser, storage: rateLimitStorage))
    soulController.addRoutes(to: soulGroup)

    // HER-196 — achievements read surface. Catalog (code-defined) joined to
    // per-tenant progress rows. Writes happen fire-and-forget from the
    // hot-paths above; this group is GET-only.
    let achievementsController = AchievementsController(
        service: achievementsService,
        logger: Logger(label: "lv.achievements"),
    )
    let achievementsGroup = router.group("/v1/achievements")
        .add(middleware: jwtAuthenticator)
        .add(middleware: RateLimitMiddleware(policy: .achievementsByUser, storage: rateLimitStorage))
    achievementsController.addRoutes(to: achievementsGroup)

    // Health ingest (HealthKit / Google Fit / manual) — protected.
    // HER-202 — read of own data is mounted on a separate group so the
    // `EntitlementMiddleware` only gates ingest. A `lapsed`/`archived`
    // tier can still read their own samples (export-window behaviour),
    // matching how `/v1/memory` read routes are wired.
    let healthController = HealthIngestController(
        fluent: services.fluent,
        eventBus: eventBus,
        logger: Logger(label: "lv.health"),
    )
    let healthIngestGroup = router.group("/v1/health").add(middleware: jwtAuthenticator)
        .add(middleware: EntitlementMiddleware(requires: .healthIngest, enforcementEnabled: services.billingEnforcementEnabled))
    healthController.addRoutes(to: healthIngestGroup)
    let healthReadGroup = router.group("/v1/health").add(middleware: jwtAuthenticator)
    healthController.addReadRoutes(to: healthReadGroup)

    // Admin: hermes-profile reconciliation. Shared-secret gated; off when
    // `admin.token` is empty.
    let reconciler = HermesProfileReconciler(
        fluent: services.fluent,
        service: hermesProfileService,
        vaultPaths: vaultPaths,
        hermesDataRoot: services.hermesDataRoot,
        logger: Logger(label: "lv.admin"),
    )
    let adminController = AdminController(reconciler: reconciler)
    let adminGroup = router.group("/v1/admin/hermes-profiles")
        .add(middleware: AdminTokenMiddleware<AppRequestContext>(expectedToken: services.adminToken))
    adminController.addRoutes(to: adminGroup)

    // HER-29 — daily 04:00 UTC self-heal pass over `hermes_profiles`. Picks
    // up rows left in `error` / `provisioning` by signup soft-fails and
    // retries `HermesProfileService.ensure`. Runs in-process via
    // `ServiceLifecycle`, mirroring `LapseArchiverService`.
    managedServices.append(HermesProfileReconcilerService(
        reconciler: reconciler,
        logger: Logger(label: "lv.admin"),
    ))

    // Admin: HER-146 Apple Health correlation engine. Shared-secret gated.
    // Host cron drives this nightly via `POST /v1/admin/health/correlate`.
    let healthCorrelationService = HealthCorrelationService(
        transport: routedTransport,
        fluent: services.fluent,
        embeddings: DeterministicEmbeddingService(),
        memories: MemoryRepository(fluent: services.fluent),
        defaultModel: services.hermesDefaultModel,
        logger: Logger(label: "lv.health-correlate"),
    )
    let healthCorrelationJob = HealthCorrelationJob(
        fluent: services.fluent,
        service: healthCorrelationService,
        logger: Logger(label: "lv.health-correlate"),
    )
    let healthAdminGroup = router.group("/v1/admin/health")
        .add(middleware: AdminTokenMiddleware<AppRequestContext>(expectedToken: services.adminToken))
    HealthAdminController(job: healthCorrelationJob).addRoutes(to: healthAdminGroup)

    // Admin: HER-147 memory scoring + pruning. Shared-secret gated.
    // Monthly host cron: `POST /v1/admin/memory/prune`.
    let memoryScoringService = MemoryScoringService(
        fluent: services.fluent,
        logger: Logger(label: "lv.memory-scoring"),
    )
    let memoryPruningService = MemoryPruningService(
        fluent: services.fluent,
        logger: Logger(label: "lv.memory-pruning"),
    )
    let memoryPruningJob = MemoryPruningJob(
        fluent: services.fluent,
        scoring: memoryScoringService,
        pruning: memoryPruningService,
        logger: Logger(label: "lv.memory-pruning"),
    )
    let memoryAdminGroup = router.group("/v1/admin/memory")
        .add(middleware: AdminTokenMiddleware<AppRequestContext>(expectedToken: services.adminToken))
    MemoryAdminController(
        scoring: memoryScoringService,
        pruning: memoryPruningService,
        job: memoryPruningJob,
    ).addRoutes(to: memoryAdminGroup)

    // Admin: billing tier override. Shared-secret gated; used for support,
    // TestFlight, and internal accounts without changing RevenueCat state.
    let billingAdminGroup = router.group("/v1/admin")
        .add(middleware: AdminTokenMiddleware<AppRequestContext>(expectedToken: services.adminToken))
    BillingAdminController(fluent: services.fluent).addRoutes(to: billingAdminGroup)

    // Device tokens (APNS / FCM) — protected.
    let deviceController = DeviceController(fluent: services.fluent)
    let deviceGroup = router.group("/v1/devices").add(middleware: jwtAuthenticator)
    deviceController.addRoutes(to: deviceGroup)

    // Onboarding state (HER-93) — server-tracked resumable onboarding.
    let onboardingController = OnboardingController(fluent: services.fluent)
    let onboardingGroup = router.group("/v1/onboarding").add(middleware: jwtAuthenticator)
    onboardingController.addRoutes(to: onboardingGroup)

    // HER-217 / HER-223 — BYO Hermes settings (/v1/settings/hermes
    // GET/PUT/DELETE/test). No EntitlementMiddleware — setting a self-
    // hosted gateway is tier-agnostic, same reasoning as /v1/auth/me/privacy
    // and /v1/health read in HER-202. Mounted only when the controller
    // could be constructed (LV_SECRET_MASTER_KEY set).
    if let byoHermesController {
        let settingsHermesGroup = router.group("/v1/settings/hermes")
            .add(middleware: jwtAuthenticator)
            .add(middleware: RateLimitMiddleware(policy: .settingsByUser, storage: rateLimitStorage))
        byoHermesController.addRoutes(to: settingsHermesGroup)
    }

    // Account management (HER-92) — DELETE /v1/account (GDPR data wipe).
    let accountDeletionService = AccountDeletionService(
        fluent: services.fluent,
        hasher: BcryptPasswordHasher(),
        vaultPaths: vaultPaths,
        hermesDataRoot: services.hermesDataRoot,
        logger: Logger(label: "lv.account"),
    )
    let accountController = AccountController(
        service: accountDeletionService,
        jwtKeys: services.jwtKeys,
    )
    let accountGroup = router.group("/v1/account").add(middleware: jwtAuthenticator)
    accountController.addRoutes(to: accountGroup)

    // Skills runtime (HER-148) — generic skill runner, per-tenant catalog,
    // cron scheduler, in-process event bus, optional context router.
    // Scaffold only: handler returns 501 until HER-169 lands. CronScheduler
    // drives the kb-compile skill on its declared cron schedule.
    // HER-193 — per-skill daily run cap guard. Reads cap values from
    // each manifest's `metadata.daily_run_cap`; SkillRunner calls
    // checkAndIncrement before LLM dispatch and recordFailure on error
    // so failed runs don't burn quota.
    let skillRunCapGuard = SkillRunCapGuard(
        fluent: services.fluent,
        logger: skillsLogger,
    )
    let skillRunner = SkillRunner(
        catalog: skillCatalog,
        transport: routedTransport,
        memories: MemoryRepository(fluent: services.fluent),
        embeddings: DeterministicEmbeddingService(),
        apns: pushService,
        defaultModel: services.hermesDefaultModel,
        fluent: services.fluent,
        vaultPaths: vaultPaths,
        capGuard: skillRunCapGuard,
        eventBus: eventBus,
        usageMeter: usageMeterService,
        logger: skillsLogger,
    )
    // HER-171 — fire-and-forget; the actor stores the subscription Tasks
    // internally so they stay alive for the lifetime of the application.
    Task { await skillRunner.startEventSubscriptions() }
    let cronScheduler = CronScheduler(
        catalog: skillCatalog,
        runner: skillRunner,
        fluent: services.fluent,
        logger: skillsLogger,
    )
    // HER-200 M4 — surface CronScheduler to ServiceGroup so `run()` is
    // invoked for the application's lifetime. No-op today (catalog empty);
    // becomes load-bearing once HER-169 lands skill dispatch.
    managedServices.append(cronScheduler)
    let skillsGroup = router.group("/v1/skills")
        .add(middleware: jwtAuthenticator)
        .add(middleware: RateLimitMiddleware(policy: .skillRunByUser, storage: rateLimitStorage))
    SkillsController(
        runner: skillRunner,
        catalog: skillCatalog,
        enforcementEnabled: services.billingEnforcementEnabled,
        logger: skillsLogger,
    ).addRoutes(to: skillsGroup)

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
            outbound: outbound,
        )
        defer {
            Task {
                await connectionManager.remove(tenantID: tenantID, connectionID: connectionID)
            }
        }

        // HER-200 L1 — see `WebSocketBroadcastGuard.evaluate(_:)` for the
        // rejection rules. Logged at warning with a specific reason so
        // misbehaving clients are diagnosable.
        let wsLogger = Logger(label: "lv.ws")
        do {
            for try await packet in inbound.messages(maxSize: WebSocketBroadcastGuard.maxMessageBytes) {
                if case let .text(message) = packet {
                    switch WebSocketBroadcastGuard.evaluate(message) {
                    case .allow:
                        await connectionManager.broadcast(tenantID: tenantID, message: message)
                    case .rejectEmpty:
                        wsLogger.warning("ws.broadcast rejected empty message tenant=\(tenantID)")
                    case let .rejectOversize(byteCount):
                        wsLogger.warning("ws.broadcast rejected oversize tenant=\(tenantID) bytes=\(byteCount)")
                    case .rejectInvalidJSON:
                        wsLogger.warning("ws.broadcast rejected non-JSON tenant=\(tenantID)")
                    case .rejectMissingType:
                        wsLogger.warning("ws.broadcast rejected missing type field tenant=\(tenantID)")
                    }
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
struct OTelServices {
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
            configuration: .init(environment: environment, exportInterval: .seconds(60)),
        )
        MetricsSystem.bootstrap(OTLPMetricsFactory(registry: registry))

        let spanExporter = try OTLPGRPCSpanExporter(configuration: .init(environment: environment))
        let spanProcessor = OTelBatchSpanProcessor(
            exporter: spanExporter,
            configuration: .init(environment: environment),
        )
        let tracer = OTelTracer(
            idGenerator: OTelRandomIDGenerator(),
            sampler: OTelConstantSampler(isOn: true),
            propagator: OTelW3CPropagator(),
            processor: spanProcessor,
            environment: environment,
            resource: resource,
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
    logger: Logger,
) -> any SMSSender {
    switch kind.lowercased() {
    case "twilio":
        return TwilioSMSSender(
            accountSID: accountSID,
            authToken: authToken,
            fromNumber: fromNumber,
            logger: logger,
        )
    case "logging":
        return LoggingSMSSender(logger: logger)
    default:
        logger.warning("unknown sms.kind=\(kind); falling back to LoggingSMSSender")
        return LoggingSMSSender(logger: logger)
    }
}

func makeHermesGateway(
    kind: String,
    dataRoot: String,
    logger: Logger,
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
    return try MeResponse(
        userId: user.requireID(),
        email: user.email,
        username: user.username,
        isVerified: user.isVerified,
        privacyNoCNOrigin: user.privacyNoCNOrigin,
        contextRouting: user.contextRouting,
    )
}

/// HER-176 / HER-172: `PUT /v1/me/privacy`. Flips
/// `users.privacy_no_cn_origin` and/or `users.context_routing`. Both
/// fields optional; only the ones present in the body are mutated.
/// Takes effect on the next inbound request — ModelRouter + ContextRouter
/// read from `User` on each request, no caching to invalidate.
private func updatePrivacyHandler(
    fluent: Fluent,
) -> @Sendable (Request, AppRequestContext) async throws -> MeResponse {
    { req, ctx in
        let user = try ctx.requireIdentity()
        let body = try await req.decode(as: UpdatePrivacyRequest.self, context: ctx)
        if let noCN = body.privacyNoCNOrigin {
            user.privacyNoCNOrigin = noCN
        }
        if let routing = body.contextRouting {
            user.contextRouting = routing
        }
        try await user.save(on: fluent.db())
        return try MeResponse(
            userId: user.requireID(),
            email: user.email,
            username: user.username,
            isVerified: user.isVerified,
            privacyNoCNOrigin: user.privacyNoCNOrigin,
            contextRouting: user.contextRouting,
        )
    }
}

struct MeBillingResponse: ResponseEncodable, Encodable {
    let tier: String
    let tierExpiresAt: Date?
    let tierOverride: String
    let inTrial: Bool
    let daysRemaining: Int
    let enforcementEnabled: Bool
}

private func meBillingHandler(
    enforcementEnabled: Bool,
) -> @Sendable (Request, AppRequestContext) async throws -> MeBillingResponse {
    { _, ctx in
        let user = try ctx.requireIdentity()

        let daysRemaining: Int = if let exp = user.tierExpiresAt {
            max(0, Calendar.current.dateComponents([.day], from: Date(), to: exp).day ?? 0)
        } else {
            0
        }

        let inTrial = user.tier == "trial" && daysRemaining > 0

        return MeBillingResponse(
            tier: user.tier,
            tierExpiresAt: user.tierExpiresAt,
            tierOverride: user.tierOverride,
            inTrial: inTrial,
            daysRemaining: daysRemaining,
            enforcementEnabled: enforcementEnabled,
        )
    }
}
