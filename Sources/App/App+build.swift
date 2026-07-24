import AsyncHTTPClient
import Configuration
import FluentKit
import FluentPostgresDriver
import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
import Hummingbird
import HummingbirdCompression
import HummingbirdFluent
import HummingbirdWebSocket
import JWTKit
import Logging
import LuminaVaultShared
import Metrics
@_spi(Logging) import OTel
import OTLPGRPC
import ServiceLifecycle
import Tracing

///  Build application
/// - Parameters:
///   - reader: configuration reader.
///   - kbCompileTransportOverride: when non-nil, substitutes for
///     `routedTransport` inside `MemoryCompileService`. Test-only escape hatch
///     for happy-path coverage that needs a deterministic chat backend.
///     Production callers leave this `nil`.
func buildApplication(
    reader: ConfigReader,
    kbCompileTransportOverride: (any HermesChatTransport)? = nil
) async throws -> some ApplicationProtocol {
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
        ? try await bootstrapOTelOnce(
            serviceName: reader.string(forKey: "otel.serviceName", default: "luminavault"),
            logLevel: logger.logLevel
        )
        : nil
    if !otelEnabled {
        bootstrapMetricsOnce()
    }

    // --- Fluent (Postgres) — optional; tests pass fluent.enabled=false ---
    let fluentEnabledStr = reader.string(forKey: "fluent.enabled", default: "true")
    let fluentEnabled = fluentEnabledStr.lowercased() != "false"
    // HER-251: Fluent gets its own logger pinned to `.notice` so `LOG_LEVEL=debug`
    // in dev compose keeps app-level debug visible without drowning every request
    // in per-query FluentKit chatter. Override with `fluent.log.level` if needed.
    var fluentLogger = Logger(label: "lv.fluent")
    fluentLogger.logLevel = reader.string(forKey: "fluent.log.level", as: Logger.Level.self, default: .notice)
    let fluent = Fluent(logger: fluentLogger)
    if fluentEnabled {
        fluent.databases.use(
            .postgres(
                configuration: .init(
                    hostname: reader.string(forKey: "postgres.host", default: "127.0.0.1"),
                    port: reader.int(forKey: "postgres.port", default: 5432),
                    username: reader.string(forKey: "postgres.user", default: "luminavault"),
                    password: reader.string(forKey: "postgres.password", default: "luminavault"),
                    database: reader.string(forKey: "postgres.database", default: "luminavault"),
                    tls: .disable
                ),
                // HER perf audit: driver default is 1 connection per event loop,
                // which serializes concurrent slow queries on a loop. Make it
                // configurable; total pool ≈ this × eventLoopCount (≈ cores).
                // Keep pool × replicas under Postgres max_connections.
                maxConnectionsPerEventLoop: reader.int(forKey: "postgres.maxConnectionsPerEventLoop", default: 4)
            ),
            as: .psql
        )
        do {
            await registerMigrations(on: fluent)
            let autoMigrateStr = reader.string(forKey: "fluent.autoMigrate", default: "true")
            if autoMigrateStr.lowercased() != "false" {
                // Serialize + memoize the migrator across concurrent in-process
                // boots (the parallel test suite shares one database) so they
                // don't race the first migration insert into a duplicate-key
                // on `_fluent_migrations`. No-op in prod. See `MigrationGate`.
                let database = reader.string(forKey: "postgres.database", default: "luminavault")
                try await MigrationGate.shared.migrateOnce(database: database) {
                    try await fluent.migrate()
                }
            }
        } catch {
            fluentLogger.error("Failed to run migrations during boot", metadata: ["error": .string("\(error)")])
            try? await fluent.shutdown()
            throw error
        }
    }

    // --- JWT keys (HMAC HS256) ---
    // HER-33: `jwt.hmac.secrets` (env `JWT_HMAC_SECRETS`) is an ordered csv of
    // `kid:secret` pairs supporting zero-downtime rotation. The first entry
    // is the active signer; the rest stay loaded so in-flight tokens still
    // verify during the rollover window. When unset, fall back to the
    // legacy single-key envs (`JWT_HMAC_SECRET` + `JWT_KID`).
    let jwtKeys = JWTKeyCollection()
    let kid: JWKIdentifier
    let jwtSecretsCSV = reader.string(forKey: "jwt.hmac.secrets", isSecret: true, default: "")
    if !jwtSecretsCSV.isEmpty {
        let entries = try parseJWTSecrets(jwtSecretsCSV)
        guard let active = entries.first else {
            fatalError("jwt.hmac.secrets parsed to empty list (env JWT_HMAC_SECRETS)")
        }
        try await loadJWTKeys(into: jwtKeys, secrets: entries)
        kid = active.kid
    } else {
        let secret = reader.string(forKey: "jwt.hmac.secret", isSecret: true, default: "")
        guard !secret.isEmpty else {
            fatalError(
                "jwt.hmac.secret must be set (env JWT_HMAC_SECRET) "
                    + "— or use JWT_HMAC_SECRETS=kid:secret,... for rotation support"
            )
        }
        kid = JWKIdentifier(string: reader.string(forKey: "jwt.kid", default: "lv-default"))
        await jwtKeys.add(hmac: HMACKey(stringLiteral: secret), digestAlgorithm: .sha256, kid: kid)
    }

    let services = ServiceContainer(
        fluent: fluent,
        jwtKeys: jwtKeys,
        jwtKID: kid,
        logLevel: logger.logLevel,
        appleClientID: reader.string(forKey: "oauth.apple.clientId", default: ""),
        googleClientID: reader.string(forKey: "oauth.google.clientId", default: ""),
        googleCalendarClientID: reader.string(forKey: "oauth.googleCalendar.clientId", default: ""),
        googleCalendarClientSecret: reader.string(forKey: "oauth.googleCalendar.clientSecret", isSecret: true, default: ""),
        googleCalendarRedirectURI: reader.string(forKey: "oauth.googleCalendar.redirectUri", default: ""),
        vaultRootPath: reader.string(forKey: "vault.rootPath", default: "/tmp/luminavault"),
        hermesGatewayKind: reader.string(forKey: "hermes.gatewayKind", default: "filesystem"),
        hermesGatewayURL: reader.string(forKey: "hermes.gatewayUrl", default: "http://hermes:8642"),
        hermesDataRoot: reader.string(forKey: "hermes.dataRoot", default: "/app/data/hermes"),
        hermesDefaultModel: reader.string(forKey: "hermes.defaultModel", default: "hermes-3"),
        hermesDefaultManagedModel: reader.string(
            forKey: "hermes.defaultManagedModel",
            default: ManagedLLMDefaults.model
        ),
        hermesManagedProviderHint: reader.string(forKey: "hermes.managedProviderHint", default: "openrouter"),
        hermesAPIKey: reader.string(forKey: "hermes.apiKey", isSecret: true, default: ""),
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
                .path
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
        emailKind: reader.string(forKey: "email.kind", default: "logging"),
        emailResendAPIKey: reader.string(forKey: "email.resend.apiKey", isSecret: true, default: ""),
        jinaAPIKey: reader.string(forKey: "jina.apiKey", isSecret: true, default: ""),
        emailFromAddress: reader.string(forKey: "email.fromAddress", default: ""),
        emailReplyTo: reader.string(forKey: "email.replyTo", default: ""),
        teamInviteBaseURL: reader.string(forKey: "team.invite.base.url", default: "http://localhost:5173"),
        // HER-XXX — default to the Mnemosyne-baked image so new tenant
        // containers ship persistent memory. Override via `hermes.perTenant.image`
        // (env HERMES_PER_TENANT_IMAGE) to pin a registry digest in prod.
        hermesPerTenantImage: reader.string(forKey: "hermes.perTenant.image", default: "luminavault-hermes:local"),
        hermesPerTenantNetwork: reader.string(forKey: "hermes.perTenant.network", default: "luminavault-hermes-net"),
        hermesPerTenantDataRootBase: reader.string(forKey: "hermes.perTenant.dataRootBase", default: "/app/data/hermes-tenants"),
        hermesPerTenantPortRangeStart: reader.int(forKey: "hermes.perTenant.portRangeStart", default: 9000),
        hermesPerTenantPortRangeEnd: reader.int(forKey: "hermes.perTenant.portRangeEnd", default: 9500),
        hermesPerTenantIdleTTLSeconds: reader.int(forKey: "hermes.perTenant.idleTTLSeconds", default: 1800),
        dockerBinaryPath: reader.string(forKey: "docker.binaryPath", default: "/usr/bin/docker"),
        // HER-330 — central Hermes self-update target. Defaults assume the
        // GHCR-published image and the compose `hermes` service name; override
        // per deployment.
        hermesCentralContainerName: reader.string(forKey: "hermes.central.containerName", default: "luminavault-hermes"),
        hermesCentralTempContainerName: reader.string(forKey: "hermes.central.tempContainerName", default: "luminavault-hermes-next"),
        hermesCentralRegistryImage: reader.string(forKey: "hermes.central.registryImage", default: "ghcr.io/luminavault/luminavault-hermes"),
        hermesCentralChannelTag: reader.string(forKey: "hermes.central.channelTag", default: "latest"),
        hermesCentralVolumePath: reader.string(forKey: "hermes.central.volumePath", default: "/app/data/hermes"),
        hermesCentralPort: reader.int(forKey: "hermes.central.port", default: 8642),
        hermesCentralTempPort: reader.int(forKey: "hermes.central.tempPort", default: 8643),
        photonSidecarURL: reader.string(forKey: "photon.sidecarUrl", default: "http://photon-sidecar:8789"),
        photonSidecarToken: reader.string(forKey: "photon.sidecarToken", isSecret: true, default: ""),
        pluginRunnerURL: reader.string(forKey: "plugin.runnerUrl", default: "http://plugin-runner:8090"),
        pluginRunnerToken: reader.string(forKey: "plugin.runnerToken", isSecret: true, default: ""),
        pluginArtifactRoot: reader.string(forKey: "plugin.artifactRoot", default: "/app/data/plugin-artifacts"),
        pluginArtifactSigningKey: reader.string(forKey: "plugin.artifactSigningKey", isSecret: true, default: "")
    )

    var appServices: [any Service] = fluentEnabled ? [fluent] : []
    let router = try buildRouter(
        reader: reader,
        services: services,
        managedServices: &appServices,
        kbCompileTransportOverride: kbCompileTransportOverride
    )
    if fluentEnabled {
        // Template v2: backfill the locked SOULCore covenant into every
        // existing tenant's SOUL.md (vault copy + Hermes mirror) before the
        // server takes traffic. Idempotent; per-tenant failures only warn.
        try await SOULCoreMigrationJob(
            fluent: fluent,
            soulService: SOULService(
                vaultPaths: VaultPathService(rootPath: services.vaultRootPath),
                hermesDataRoot: services.hermesDataRoot,
                logger: Logger(label: "lv.soul")
            ),
            logger: Logger(label: "lv.soul.migrate")
        ).run()
    }
    if fluentEnabled {
        let lapseArchiver = LapseArchiverJob(
            fluent: fluent,
            vaultPaths: VaultPathService(rootPath: services.vaultRootPath),
            coldStoragePath: services.billingColdStoragePath,
            logger: Logger(label: "lv.billing.lapse-archiver")
        )
        appServices.append(LapseArchiverService(
            job: lapseArchiver,
            logger: Logger(label: "lv.billing.lapse-archiver")
        ))
    }
    if let otelServices {
        appServices.append(otelServices.metrics)
        appServices.append(otelServices.tracer)
        if let logs = otelServices.logs {
            appServices.append(logs)
        }
    }
    return Application(
        router: router,
        server: .http1WebSocketUpgrade(webSocketRouter: router),
        configuration: ApplicationConfiguration(reader: reader.scoped(to: "http")),
        services: appServices,
        logger: logger
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
    kbCompileTransportOverride: (any HermesChatTransport)? = nil
) throws -> Router<AppRequestContext> {
    let router = Router(context: AppRequestContext.self)
    // HER-310 — gate DB-ticking background services (cron, reconciler, the
    // achievements worker) so they never start when there's no database
    // (no-DB tests) where their `fluent.db()` calls fatalError with
    // "No default database configured" and kill the test binary.
    let fluentEnabled = reader.string(forKey: "fluent.enabled", default: "true").lowercased() != "false"
    router.addMiddleware {
        TracingMiddleware()
        MetricsMiddleware()
        // HER — structured request logging: outcome (status), duration, and
        // redacted error on failure, with level by status class. Replaces
        // `LogRequestsMiddleware` (start-only, no outcome). Correlation id +
        // trace ids come from the request context + TracingMiddleware above.
        RequestLogMiddleware(successLevel: .info)
        OpenAPIRequestContextMiddleware()
    }
    router.middlewares.add(RequestDecompressionMiddleware())
    // SSE-aware wrapper: skips gzip for `text/event-stream` so chat token
    // frames stream live instead of being buffered in the zlib window and
    // flushed in one burst at stream end (which broke the typewriter effect).
    router.middlewares.add(SSEAwareResponseCompressionMiddleware(minimumResponseSizeToCompress: 512))
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
    // Apple App Site Association — backs Sign in with Apple associated domain
    // and WebAuthn/passkey credentials for the iOS app (`TEAMID.bundleID`).
    // Public + unauthenticated; served at the WebAuthn relying-party domain
    // (api.luminavault.fyi). Static for the single production app identity
    // `com.lumina.fernando` (team 84X9WYBF36).
    router.get("/.well-known/apple-app-site-association") { _, _ -> Response in
        let json = #"{"webcredentials":{"apps":["84X9WYBF36.com.lumina.fernando"]}}"#
        var headers = HTTPFields()
        headers[.contentType] = "application/json"
        return Response(
            status: .ok,
            headers: headers,
            body: .init(byteBuffer: ByteBuffer(string: json))
        )
    }
    // HER-227 — root greeting served as a plain Hummingbird route. The
    // generated `APIProtocol` server stubs were never registered for any
    // other path; openapi-generator now emits `types` only (see
    // `Sources/AppAPI/openapi-generator-config.yaml`). The yaml at
    // `Sources/AppAPI/openapi.yaml` is the documentation contract; every
    // other route is hand-written below.
    router.get("/") { _, _ -> String in "Hello!" }

    // Auth routes
    // HER-33 — every email OTP surface (MFA challenge, password reset,
    // signup verification, magic-link sign-in) routes through one factory
    // so a single `EMAIL_KIND=resend` flip activates production delivery.
    let makeEmailSender: (String) -> any EmailOTPSender = { label in
        makeEmailOTPSender(
            kind: services.emailKind,
            apiKey: services.emailResendAPIKey,
            fromAddress: services.emailFromAddress,
            replyTo: services.emailReplyTo,
            logger: Logger(label: label)
        )
    }
    let mfaService = DefaultMFAService(
        fluent: services.fluent,
        sender: makeEmailSender("lv.mfa"),
        generator: DefaultOTPCodeGenerator()
    )
    let resetSender = makeEmailSender("lv.reset")
    let resetGen = DefaultOTPCodeGenerator()
    let verifySender = makeEmailSender("lv.verify")
    let verifyGen = DefaultOTPCodeGenerator()
    let vaultPaths = VaultPathService(rootPath: services.vaultRootPath)
    let hermesLogger = Logger(label: "lv.hermes")
    let hermesGateway: any HermesGateway = makeHermesGateway(
        kind: services.hermesGatewayKind,
        dataRoot: services.hermesDataRoot,
        logger: hermesLogger
    )
    if services.hermesGatewayKind == "filesystem" {
        do {
            try HermesDataPathService(hermesDataRoot: services.hermesDataRoot)
                .ensureProfilesDirectoryWritable(logger: hermesLogger)
        } catch {
            hermesLogger.critical("hermes profiles bootstrap failed: \(error)")
            throw error
        }
    }
    let hermesProfileService = HermesProfileService(
        fluent: services.fluent,
        gateway: hermesGateway,
        vaultPaths: vaultPaths
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
        logger: Logger(label: "lv.apns")
    )
    // HER-206 — EventBus constructed early so AchievementsService can
    // publish .achievementUnlocked into the same instance MeTodayCache
    // subscribes to. SkillRunner / capture publishers reuse this bus
    // below; we share one bus across the app.
    let eventBus = EventBus(logger: Logger(label: "lv.eventbus"))

    // HER-196 — usage-driven achievement progress + per-unlock APNS push.
    // Constructed once and threaded into every controller hot-path (Memory,
    // LLM, KBCompile, Query, Vault, SOUL) plus the read-only catalog
    // endpoints under /v1/achievements.
    let achievementsService = AchievementsService(
        fluent: services.fluent,
        pushService: pushService,
        eventBus: eventBus,
        logger: Logger(label: "lv.achievements")
    )
    // HER-310 — controller hot-paths enqueue achievement events here instead of
    // `Task.detached { await achievements.recordAndPush(...) }`. The worker owns
    // the DB write on the app's long-lived Fluent and is registered AFTER
    // `fluent` in managedServices, so it stops draining BEFORE Fluent shuts down
    // → no `.db()` call races a torn-down database (the signal-5 crash).
    let achievementsWorker = AchievementsWorker(
        service: achievementsService,
        logger: Logger(label: "lv.achievements.worker")
    )
    if fluentEnabled {
        managedServices.append(achievementsWorker)
    }
    // Retrieval-quality telemetry (additive). Registered AFTER `fluent` (via
    // `achievementsWorker` ordering) so it drains before DB teardown. Wired
    // into the chat/query/agentic grounding paths below; nil when disabled.
    let retrievalTelemetryEnabled = reader.string(forKey: "retrieval.telemetry.enabled", default: "true").lowercased() != "false"
    let retrievalTelemetryWorker: RetrievalTelemetryWorker? = (fluentEnabled && retrievalTelemetryEnabled)
        ? RetrievalTelemetryWorker(fluent: services.fluent, logger: Logger(label: "lv.retrieval.telemetry"))
        : nil
    if let retrievalTelemetryWorker {
        managedServices.append(retrievalTelemetryWorker)
    }
    let vaultMapToolEnabled = reader.string(forKey: "hermes.tool.vaultMap.enabled", default: "true").lowercased() != "false"
    let authRepo = DatabaseAuthRepository(fluent: services.fluent)
    let soulService = SOULService(
        vaultPaths: vaultPaths,
        hermesDataRoot: services.hermesDataRoot,
        logger: Logger(label: "lv.soul")
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
        logger: Logger(label: "lv.auth")
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
    // HER-200 M3 — single config key controls rate-limit storage. Memory
    // is fine for single-process; Redis seam reserved for multi-replica.
    let rateLimitStorage = makeRateLimitStorage(
        kind: services.rateLimitStorageKind,
        isProduction: reader.string(forKey: "lv.environment", default: "dev") != "dev",
        logger: Logger(label: "lv.ratelimit")
    )
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
        logger: Logger(label: "lv.auth.phone")
    ).addRoutes(to: router)
    let magicLinkOTPGenerator: any OTPCodeGenerator = services.magicLinkFixedOTP.isEmpty
        ? DefaultOTPCodeGenerator()
        : FixedOTPCodeGenerator(code: services.magicLinkFixedOTP)
    EmailMagicLinkController(
        authService: authService,
        emailSender: makeEmailSender("lv.auth.magic"),
        generator: magicLinkOTPGenerator,
        challengeStore: preAuthStore,
        rateLimitStorage: rateLimitStorage,
        logger: Logger(label: "lv.auth.magic")
    ).addRoutes(to: router)
    XOAuthController(
        authService: authService,
        xClient: DefaultXAPIClient(logger: Logger(label: "lv.auth.x")),
        logger: Logger(label: "lv.auth.x")
    ).addRoutes(to: multiProviderGroup)

    // Protected (JWT-required) routes
    let jwtAuthenticator = JWTAuthenticator(jwtKeys: services.jwtKeys, fluent: services.fluent)
    // HER-273 — resolve active Hermes persona from inbound
    // `X-Hermes-Profile: <slug>` header. Lazy-creates a "default"
    // persona row when a pre-B1 tenant first touches a wired route.
    let hermesProfileMiddleware = HermesProfileMiddleware(
        fluent: services.fluent,
        profiles: hermesProfileService,
        logger: Logger(label: "lv.hermes-profile")
    )
    let meGroup = router.group("/v1/auth")
        .add(middleware: jwtAuthenticator)
    meGroup.get("/me", use: meHandler)
    meGroup.put("/me/privacy", use: updatePrivacyHandler(fluent: services.fluent))
    meGroup.get("/me/billing", use: meBillingHandler(enforcementEnabled: services.billingEnforcementEnabled))
    meGroup.get("/me/usage", use: meUsageHandler(fluent: services.fluent))

    // HER-216 — authenticated passkey management (list / revoke).
    let webAuthnAuthedGroup = router.group("/v1/auth")
        .add(middleware: jwtAuthenticator)
    webAuthnService.addAuthenticatedRoutes(to: webAuthnAuthedGroup)

    let billingGroup = router.group("/v1/billing")
    RevenueCatWebhookController(
        fluent: services.fluent,
        webhookSecret: services.revenuecatWebhookSecret,
        logger: Logger(label: "lv.billing.revenuecat-webhook")
    ).addRoutes(to: billingGroup)

    // HER-172 — SkillCatalog needs to be in scope for the ContextRouter
    // middleware on `/v1/llm` below; the full Skills runtime (runner,
    // event bus, cron) is constructed further down. SkillCatalog itself
    // has no dependencies on those, so hoisting it is safe.
    let skillsLogger = Logger(label: "lv.skills")
    let scanBuiltinSkills = reader.string(forKey: "skills.builtinScan.enabled", default: "true").lowercased() != "false"
    let skillCatalog = SkillCatalog(
        vaultPaths: vaultPaths,
        scanBuiltin: scanBuiltinSkills,
        logger: skillsLogger
    )
    // HER-171 — EventBus is shared across every publisher (vault, health,
    // memory, achievements) and the SkillRunner / MeTodayCache subscribers.
    // Constructed earlier (above AchievementsService); reused here.

    // LLM (Hermes-backed) routes — protected.
    guard let hermesURL = URL(string: services.hermesGatewayURL) else {
        fatalError("invalid hermes.gatewayUrl: \(services.hermesGatewayURL)")
    }
    // HER-186 / HER-254 — Bearer token guard. The central Hermes
    // `api_server` enforces `API_SERVER_KEY`; Hummingbird must send
    // `Authorization: Bearer <key>` on every outbound call (wired in
    // `HermesGatewayAdapter`, `URLSessionHermesChatTransport`,
    // `DefaultHermesLLMStreamService`). Fail closed in any non-dev
    // profile so a missing key cannot silently degrade prod to
    // unauthenticated traffic.
    let lvEnvironment = reader.string(forKey: "lv.environment", default: "dev")
    // Audit S3 — an empty `cors.allowedOrigins` falls back to `CORSMiddleware(.all)`
    // (see the CORS block above), which is only safe for localhost dev. Refuse to
    // boot a non-dev environment with no origin allowlist so a misconfigured deploy
    // can't silently accept cross-origin requests from anywhere.
    if lvEnvironment != "dev", services.corsAllowedOrigins.isEmpty {
        fatalError(
            "cors.allowedOrigins must be set when LV_ENVIRONMENT=\(lvEnvironment) "
                + "(empty falls back to allow-all CORS). Set CORS_ALLOWEDORIGINS to your web origin(s)."
        )
    }
    if services.hermesAPIKey.isEmpty {
        if lvEnvironment != "dev" {
            fatalError(
                "HERMES_API_KEY required when LV_ENVIRONMENT=\(lvEnvironment). "
                    + "Run `make hermes-bootstrap` and restart the stack."
            )
        }
        Logger(label: "lv.hermes").warning(
            "HERMES_API_KEY not set — outbound Hermes gateway calls will be unauthenticated (dev only). Run `make hermes-bootstrap` and restart the stack."
        )
    }
    if !services.pluginRunnerToken.isEmpty, services.pluginArtifactSigningKey.utf8.count < 32 {
        if lvEnvironment != "dev" {
            fatalError(
                "PLUGIN_ARTIFACT_SIGNING_KEY must contain at least 32 bytes when the plugin runner is enabled. "
                    + "Use a secret independent from PLUGIN_RUNNER_TOKEN."
            )
        }
        Logger(label: "lv.marketplace").warning(
            "PLUGIN_ARTIFACT_SIGNING_KEY is missing or too short; third-party WASM publishing is disabled."
        )
    }

    // HER-217 / HER-223 — BYO Hermes endpoint config + resolver.
    // Constructed only when `LV_SECRET_MASTER_KEY` is set so tests that
    // don't exercise BYO Hermes leave the env unset and the routes 404.
    // When unset, every chat call falls through to the managed Hermes
    // default — identical to pre-BYO behaviour.
    let byoHermesLogger = Logger(label: "lv.byo-hermes")
    let legacySecretMasterKey = reader.string(forKey: "secret.masterKey", default: "")
    let secretMasterKey = reader.string(forKey: "lv.secretMasterKey", default: legacySecretMasterKey)
    let byoHermesAllowPrivate = reader.string(forKey: "byoHermes.allowPrivate", default: "false")
        .lowercased() == "true"
    // BYO_HERMES_REQUIRE_HTTPS — audit S2: defaults to TRUE outside dev so a prod
    // tenant can't silently send its bearer/auth header to a plain-http Hermes.
    // Dev still defaults false for localhost/bare-IP convenience. Operators can
    // override either way with the env var. Private-range SSRF blocks apply
    // regardless (see `byoHermesAllowPrivate`).
    let byoHermesRequireHttps = reader.string(
        forKey: "byoHermes.requireHttps",
        default: lvEnvironment == "dev" ? "false" : "true"
    ).lowercased() == "true"
    // BYO_HERMES_ALLOW_TAILNET_HTTP — waives requireHttps for endpoints whose
    // every resolved address is a Tailscale one (100.64.0.0/10 or
    // fd7a:115c:a1e0::/48; WireGuard already encrypts the link) and exempts
    // Tailscale IPv6 from the fc00::/7 block. Default true: a tailnet target
    // is only reachable if this server was deliberately joined to it.
    let byoHermesAllowTailnetHttp = reader.string(
        forKey: "byoHermes.allowTailnetHttp",
        default: "true"
    ).lowercased() == "true"
    var byoHermesController: HermesConfigController?
    var byoHermesMiddleware: HermesResolutionMiddleware?
    // P3 — BYO-Hermes capabilities probe (feature-detect the remote box's
    // /v1/capabilities so clients can gate panes live/read-only/unsupported).
    var hermesCapabilitiesService: HermesRemoteCapabilitiesService?
    // HER-252 — captured from the same SecretBox the BYO Hermes flow
    // builds so the new per-user provider credential surface can reuse
    // the AES-GCM helper without a second master-key load.
    var secretBoxRef: SecretBox?
    var hermesEndpointResolver: HermesEndpointResolver?
    // HER-240a — per-tenant Hermes container manager + xai-oauth service.
    // Gated on the same SecretBox the BYO Hermes flow depends on because
    // the tenant's encrypted `API_SERVER_KEY` is sealed with the same KDF.
    var xaiOAuthController: XaiOAuthController?
    // Nous Subscription Integration — per-tenant Nous Portal OAuth device-code
    // service. Built alongside the xai bits; shares the same container manager
    // + docker exec. Gated on the same SecretBox branch.
    var nousOAuthController: NousOAuthController?
    // HER-240c — Grok runtime proxy. Built alongside the xai bits so it
    // shares the same container manager instance.
    var grokController: GrokController?
    // HER-241 — per-user Hermes messaging gateway configurator. Gated on
    // the same SecretBox as BYO Hermes; gateway config is sealed at rest.
    var hermesGatewaysController: HermesGatewaysController?
    // HER-330 — owner-triggered "Update Hermes" controller. Built inside the
    // secret-key branch where the docker exec + container manager exist.
    var hermesUpdateController: HermesUpdateController?
    // HER-43 Slice 3b — Hermes Hub skill install/uninstall via docker exec into
    // the tenant's container. Built in the same secret branch (needs the docker
    // exec + container manager); mounted under /v1/plugins (tenant JWT).
    var hubSkillsService: HermesHubSkillsService?
    // Hermes cron bridge — list/create the tenant's `hermes cron` jobs via
    // docker exec (managed). Built in the same secret branch; mounted at
    // /v1/me/hermes/cron.
    var cronBridgeService: CronBridgeService?
    // Cron bridge deps captured from the secret branch; the service is assembled
    // after `routedTransport` exists (NL→spec classifier needs it).
    var cronDocker: (any DockerExec)?
    var cronContainerManager: HermesContainerManager?
    var cronSSRF: SSRFGuard?
    // HER-134 — LocalHermes text-embedding adapter resolves the running
    // per-tenant container via `HermesContainerManager.handle`. Outside
    // the BYO branch we leave the resolver no-op; LocalHermes then falls
    // through with `.endpointMissing` and the chain advances.
    var localHermesHandleResolver: LocalHermesEmbeddingService.HandleResolver = { _ in nil }
    // Late-bound for xAI oauth marker seeding + LLM BYOK .xai oauth resolve.
    // Filled after secret + containerManager are ready. Boxed to satisfy
    // Sendable closure capture rules when wiring into UserCredentialStore.
    final class XaiContainerResolverBox: @unchecked Sendable {
        var resolver: (@Sendable (UUID) async -> HermesContainerHandle?)?
    }
    let xaiContainerResolverBox = XaiContainerResolverBox()
    var userCredentialStore: UserCredentialStore? = nil
    if !secretMasterKey.isEmpty {
        do {
            let secretBox = try SecretBox(masterKeyBase64: secretMasterKey)
            secretBoxRef = secretBox
            userCredentialStore = UserCredentialStore(
                fluent: services.fluent,
                secretBox: secretBox,
                logger: Logger(label: "lv.routing"),
                xaiContainerResolver: { tid in
                    await xaiContainerResolverBox.resolver?(tid) ?? nil
                }
            )
            let ssrfGuard = SSRFGuard(
                allowPrivateRanges: byoHermesAllowPrivate,
                requireHTTPS: byoHermesRequireHttps,
                allowTailnetHTTP: byoHermesAllowTailnetHttp
            )
            byoHermesController = HermesConfigController(
                fluent: services.fluent,
                secretBox: secretBox,
                ssrfGuard: ssrfGuard,
                probeSession: BYOHTTP.session,
                logger: byoHermesLogger
            )
            let resolver = HermesEndpointResolver(
                fluent: services.fluent,
                secretBox: secretBox,
                ssrfGuard: ssrfGuard,
                defaultBaseURL: hermesURL,
                logger: byoHermesLogger
            )
            hermesEndpointResolver = resolver
            byoHermesMiddleware = HermesResolutionMiddleware(
                resolver: resolver,
                logger: byoHermesLogger
            )
            hermesCapabilitiesService = HermesRemoteCapabilitiesService(
                fluent: services.fluent,
                resolver: resolver,
                probeSession: BYOHTTP.session,
                logger: byoHermesLogger
            )
            let xaiLogger = Logger(label: "lv.xai-oauth")
            let dockerExec = ProcessDockerExec(
                binaryPath: services.dockerBinaryPath,
                logger: Logger(label: "lv.docker")
            )
            let containerManager = HermesContainerManager(
                docker: dockerExec,
                fluent: services.fluent,
                secretBox: secretBox,
                config: HermesContainerManager.Config(
                    image: services.hermesPerTenantImage,
                    network: services.hermesPerTenantNetwork,
                    dataRootBase: services.hermesPerTenantDataRootBase,
                    portRangeStart: services.hermesPerTenantPortRangeStart,
                    portRangeEnd: services.hermesPerTenantPortRangeEnd,
                    idleTTLSeconds: services.hermesPerTenantIdleTTLSeconds,
                    defaultModel: services.hermesDefaultModel,
                    // Operator fallback for the per-tenant Mnemosyne toggle
                    // (env `MNEMOSYNE_ENABLED`); `User.mnemosyneEnabled` wins
                    // when a row is loaded. On by default — Mnemosyne is the
                    // managed default memory layer.
                    mnemosyneDefault: reader.string(forKey: "mnemosyne.enabled", default: "true").lowercased() == "true"
                ),
                logger: Logger(label: "lv.hermes-tenant")
            )
            // HER-134 — wire LocalHermes text embedding to the live
            // container manager. `handle` is read-only; if the tenant has
            // no running container the LocalHermes adapter surfaces
            // `.endpointMissing` and the fallback chain advances.
            localHermesHandleResolver = { tenantID in
                try await containerManager.handle(tenantID: tenantID)
            }
            // HER-240 follow-up — make xAI oauth-linked credentials resolvable
            // for the LLM BYOK path (Grok models in the Intelligence picker).
            xaiContainerResolverBox.resolver = { tenantID in
                try? await containerManager.handle(tenantID: tenantID)
            }
            // HER-43 Slice 3b — hub skill install/uninstall into the tenant's
            // container (CLI-only upstream → docker exec). Reuses the 3a
            // read-only HermesSkillsClient to return the refreshed list.
            hubSkillsService = HermesHubSkillsService(
                docker: dockerExec,
                containerManager: containerManager,
                installedSkillsClient: HermesSkillsClient(logger: Logger(label: "lv.plugins.hermes-skills")),
                logger: Logger(label: "lv.plugins.hub-install")
            )
            // Cron bridge deps captured here (docker/container/ssrf live in this
            // branch); the service is built after `routedTransport` (the
            // NL→spec classifier needs it).
            cronDocker = dockerExec
            cronContainerManager = containerManager
            cronSSRF = ssrfGuard
            let xaiProcessRegistry = XaiOAuthProcessRegistry()
            let xaiService = XaiOAuthService(
                containerManager: containerManager,
                sessionStore: XaiOAuthSessionStore(),
                backend: LiveXaiOAuthBackend(
                    docker: dockerExec,
                    registry: xaiProcessRegistry,
                    logger: xaiLogger
                ),
                fluent: services.fluent,
                logger: xaiLogger,
                userCredentialStore: userCredentialStore
            )
            xaiOAuthController = XaiOAuthController(
                service: xaiService,
                logger: xaiLogger
            )
            // Nous Subscription Integration — Nous Portal OAuth device-code
            // service. Shares the container manager + docker exec with xai.
            let nousLogger = Logger(label: "lv.nous-oauth")
            let nousProcessRegistry = NousOAuthProcessRegistry()
            let nousService = NousOAuthService(
                containerManager: containerManager,
                sessionStore: NousOAuthSessionStore(),
                backend: LiveNousOAuthBackend(
                    docker: dockerExec,
                    registry: nousProcessRegistry,
                    logger: nousLogger
                ),
                fluent: services.fluent,
                logger: nousLogger
            )
            nousOAuthController = NousOAuthController(
                service: nousService,
                logger: nousLogger
            )
            // HER-240c — Grok runtime proxy shares the container manager.
            // Use the AsyncHTTPClient-managed shared client so the process
            // never deinits an un-shutdown HTTPClient (which preconditions
            // and SIGILLs on Linux at process exit, taking CI tests with it).
            let grokHTTPClient = HTTPClient.shared
            grokController = GrokController(
                containerManager: containerManager,
                proxy: HermesGrokProxy(
                    httpClient: grokHTTPClient,
                    logger: Logger(label: "lv.grok-proxy")
                ),
                logger: Logger(label: "lv.grok")
            )
            // HER-241 — Hermes messaging gateway controller. Probes the
            // user's Hermes `/v1/health` for reachability on /test; cannot
            // verify per-gateway operational status (Hermes exposes no
            // admin HTTP API yet).
            let gatewaysLogger = Logger(label: "lv.hermes-gateways")
            // Actuation service: re-seeds the tenant `.env` from saved gateway
            // rows and recreates the container, streaming progress over SSE.
            // Health probe hits the container's loopback-published OpenAI
            // gateway (same shape as the central self-update probe).
            let gatewayHealthProbe: HermesGatewayApplyService.HealthProbe = { port, apiKey in
                var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/models")!)
                req.timeoutInterval = 5
                req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                guard let (_, response) = try? await URLSession.shared.data(for: req),
                      let http = response as? HTTPURLResponse
                else { return false }
                return (200 ..< 300).contains(http.statusCode)
            }
            let gatewayApplyService = HermesGatewayApplyService(
                fluent: services.fluent,
                containerManager: containerManager,
                healthProbe: gatewayHealthProbe,
                logger: gatewaysLogger
            )
            // WhatsApp QR pairing: runs `hermes whatsapp` in the tenant
            // container and streams the QR to the app. Shares the docker exec
            // + container manager with the other Hermes services.
            let whatsAppPairingService = WhatsAppPairingService(
                containerManager: containerManager,
                backend: LiveWhatsAppPairingBackend(
                    docker: dockerExec,
                    logger: gatewaysLogger
                ),
                logger: gatewaysLogger
            )
            let photonClient: PhotonSidecarClienting? = {
                guard !services.photonSidecarURL.isEmpty, !services.photonSidecarToken.isEmpty else { return nil }
                guard let url = URL(string: services.photonSidecarURL) else { return nil }
                return PhotonSidecarClient(
                    baseURL: url,
                    token: services.photonSidecarToken,
                    logger: Logger(label: "lv.photon.sidecar")
                )
            }()

            let photonProvisioningService = PhotonProvisioningService(
                fluent: services.fluent,
                secretBox: secretBox,
                logger: Logger(label: "lv.photon.provisioning"),
                sidecarClient: photonClient
            )

            // Delivery service for inbound from sidecar -> tenant Hermes injection + reply
            let photonDeliveryService: PhotonDeliveryService? = {
                guard let client = photonClient else { return nil }
                return PhotonDeliveryService(
                    photonClient: client,
                    getHandle: { tenantID in
                        let h = try await containerManager.ensureRunning(tenantID: tenantID)
                        return (port: h.port, apiKey: h.apiServerKey)
                    },
                    logger: Logger(label: "lv.photon.delivery")
                )
            }()

            hermesGatewaysController = HermesGatewaysController(
                fluent: services.fluent,
                secretBox: secretBox,
                gatewayClient: HermesGatewayClient(logger: gatewaysLogger),
                applyService: gatewayApplyService,
                whatsAppPairingService: whatsAppPairingService,
                photonSidecarClient: photonClient,
                photonProvisioningService: photonProvisioningService,
                photonDeliveryService: photonDeliveryService,
                logger: gatewaysLogger
            )

            // HER-330 — central Hermes self-update. Reuses the same docker
            // exec + container manager. The health probe hits the (loopback)
            // published port of a candidate container's OpenAI gateway.
            let updateLogger = Logger(label: "lv.hermes-update")
            let healthProbe: CentralHermesManager.HealthProbe = { port, apiKey in
                var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/models")!)
                req.timeoutInterval = 5
                req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                guard let (_, response) = try? await URLSession.shared.data(for: req),
                      let http = response as? HTTPURLResponse
                else { return false }
                return (200 ..< 300).contains(http.statusCode)
            }
            let centralManager = CentralHermesManager(
                docker: dockerExec,
                config: CentralHermesManager.Config(
                    containerName: services.hermesCentralContainerName,
                    tempContainerName: services.hermesCentralTempContainerName,
                    registryImage: services.hermesCentralRegistryImage,
                    defaultChannelTag: services.hermesCentralChannelTag,
                    network: services.hermesPerTenantNetwork,
                    volumePath: services.hermesCentralVolumePath,
                    port: services.hermesCentralPort,
                    tempPort: services.hermesCentralTempPort,
                    apiServerKey: services.hermesAPIKey,
                    mnemosyneDataDir: "/opt/data/mnemosyne"
                ),
                healthProbe: healthProbe,
                logger: updateLogger
            )
            let updateService = HermesUpdateService(
                fluent: services.fluent,
                central: centralManager,
                containerManager: containerManager,
                logger: updateLogger
            )
            hermesUpdateController = HermesUpdateController(
                service: updateService,
                logger: updateLogger
            )
        } catch {
            fatalError("LV_SECRET_MASTER_KEY malformed (must be 32 bytes base64): \(error)")
        }
    } else {
        byoHermesLogger.warning(
            "BYO Hermes disabled — set LV_SECRET_MASTER_KEY to enable /v1/settings/hermes"
        )
    }

    // HER-165 routing — single shared registry + router + transport
    // injected into every chat-using service. Today the registry holds
    // only the Hermes adapter and the router always picks `hermesGateway`,
    // so the runtime behaviour is identical to the previous direct path;
    // adding `together` / `groq` / `openRouter` etc. is a registration
    // line each (HER-162..HER-164).
    let routingLogger = Logger(label: "lv.routing")

    let userLLMPreferenceRepo = UserLLMPreferenceRepository(
        fluent: services.fluent,
        logger: routingLogger
    )
    let providerFailoverLogger = ProviderFailoverLogger(
        fluent: services.fluent,
        logger: routingLogger
    )

    // HER-300 — test-only stub chat provider, selected exclusively via
    // `llm.provider=stub`. It replaces the real `HermesGatewayAdapter`
    // under `.hermesGateway` so a `managed`-mode chat (which always
    // resolves to the table's last-resort gateway route) gets a canned,
    // network-free reply. Unreachable in prod unless the env var is set.
    let llmProviderName = reader.string(forKey: ConfigKey("llm.provider"), default: "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
    let gatewayAdapter: any ProviderAdapter = if llmProviderName == "stub" {
        StubChatAdapter(
            replyContent: reader.string(forKey: ConfigKey("llm.stub.replyContent"), default: "Hello from the LuminaVault default brain."),
            replyModel: reader.string(forKey: ConfigKey("llm.stub.replyModel"), default: "stub-default-brain")
        )
    } else {
        HermesGatewayAdapter(
            // SSRF hardening: no-redirect session so a BYO endpoint can't 30x
            // the proxied request to an internal/metadata host post-validation.
            baseURL: hermesURL,
            session: BYOHTTP.session,
            logger: routingLogger,
            defaultAuthHeader: services.hermesAPIKey.isEmpty ? nil : "Bearer \(services.hermesAPIKey)"
        )
    }
    var providerAdapters: [any ProviderAdapter] = [gatewayAdapter]
    // Canonical platform-funded OpenRouter pool. `OPENROUTER_API_KEY` remains
    // a compatibility alias for the Hermes sidecar and older deployments.
    let platformOpenRouterKey = reader.string(
        forKey: ConfigKey("llm.provider.openRouter.apiKey"),
        isSecret: true,
        default: reader.string(forKey: ConfigKey("openrouter.api_key"), isSecret: true, default: "")
    )
    // HER-199 — register Gemini provider when API key is configured.
    if !services.geminiAPIKey.isEmpty {
        providerAdapters.append(GeminiContentsAdapter(
            apiKey: services.geminiAPIKey,
            session: .shared,
            logger: routingLogger
        ))
    }
    // HER-164 — OpenAI-compatible adapter covers Together, Groq,
    // Fireworks, DeepInfra, and DeepSeek-direct in one struct. Each
    // provider registers only when its apiKey is present; the base
    // URL defaults to the provider's production host but can be
    // overridden via `llm.provider.<key>.baseURL`.
    for kind in [ProviderKind.together, .groq, .fireworks, .deepInfra, .deepseekDirect] {
        let key = kind.rawValue
        let apiKey = reader.string(forKey: ConfigKey("llm.provider.\(key).apiKey"), isSecret: true, default: "")
        guard !apiKey.isEmpty else { continue }
        let rawBaseURL = reader.string(forKey: ConfigKey("llm.provider.\(key).baseURL"), default: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let baseURL = rawBaseURL.isEmpty
            ? OpenAICompatibleAdapter.defaultBaseURL(for: kind)
            : (URL(string: rawBaseURL) ?? OpenAICompatibleAdapter.defaultBaseURL(for: kind))
        providerAdapters.append(OpenAICompatibleAdapter(
            kind: kind,
            apiKey: apiKey,
            baseURL: baseURL,
            session: .shared,
            logger: routingLogger
        ))
    }
    // HER-252 — register adapters for the per-user-credential providers
    // (xai, openai, openRouter via OpenAICompatibleAdapter; anthropic +
    // ollama via their bespoke adapters). Each is registered
    // unconditionally so a user can attach a personal key at any time;
    // the deployment env key is the fallback when no user creds exist.
    // `.custom` (P2) — generic OpenAI-compatible endpoint. No env key or
    // base URL; both are resolved per-user from `user_provider_credentials`
    // on every call. Registered unconditionally so any tenant can attach one.
    for kind in [ProviderKind.xai, .openai, .openRouter, .nous, .custom] {
        let configuredKey = reader.string(forKey: ConfigKey("llm.provider.\(kind.rawValue).apiKey"), isSecret: true, default: "")
        let envKey = kind == .openRouter && configuredKey.isEmpty ? platformOpenRouterKey : configuredKey
        let rawBaseURL = reader.string(forKey: ConfigKey("llm.provider.\(kind.rawValue).baseURL"), default: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let baseURL = rawBaseURL.isEmpty
            ? OpenAICompatibleAdapter.defaultBaseURL(for: kind)
            : (URL(string: rawBaseURL) ?? OpenAICompatibleAdapter.defaultBaseURL(for: kind))
        let xaiResolver: (@Sendable (UUID) async -> HermesContainerHandle?)? = (kind == .xai) ? xaiContainerResolverBox.resolver : nil
        providerAdapters.append(OpenAICompatibleAdapter(
            kind: kind,
            apiKey: envKey,
            baseURL: baseURL,
            session: .shared,
            logger: routingLogger,
            userCredentials: userCredentialStore,
            xaiOAuthContainerResolver: xaiResolver
        ))
    }
    let anthropicEnvKey = reader.string(forKey: ConfigKey("llm.provider.anthropic.apiKey"), isSecret: true, default: "")
    let anthropicRawBaseURL = reader.string(forKey: ConfigKey("llm.provider.anthropic.baseURL"), default: "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    providerAdapters.append(AnthropicAdapter(
        apiKey: anthropicEnvKey,
        baseURL: anthropicRawBaseURL.isEmpty ? URL(string: "https://api.anthropic.com")! : (URL(string: anthropicRawBaseURL) ?? URL(string: "https://api.anthropic.com")!),
        session: .shared,
        logger: routingLogger,
        userCredentials: userCredentialStore
    ))
    let ollamaRawBaseURL = reader.string(forKey: ConfigKey("llm.provider.ollama.baseURL"), default: "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    providerAdapters.append(OllamaAdapter(
        defaultBaseURL: ollamaRawBaseURL.isEmpty ? URL(string: "http://localhost:11434")! : (URL(string: ollamaRawBaseURL) ?? URL(string: "http://localhost:11434")!),
        session: .shared,
        logger: routingLogger,
        userCredentials: userCredentialStore
    ))
    // HER-161 — env-loaded provider registry. Reads
    // `llm.provider.<key>.apiKey` / `.baseURL` for anthropic, openai,
    // gemini, together, groq, fireworks, deepseekDirect — missing keys
    // disable that provider rather than crashing the boot. Registered
    // as a `Service` so `ServiceGroup` retains it for the app lifetime.
    let providerRegistry = ProviderRegistry.from(
        reader: reader,
        adapters: providerAdapters,
        logger: routingLogger
    )
    managedServices.append(providerRegistry)
    // HER-161 — capability-tier table router. Picks `(provider, model)`
    // from a static matrix keyed on `(tier, capability)`, honors the
    // user's `privacy_no_cn_origin` flag, and always falls back to the
    // Hermes gateway when no upstream is enabled.
    let tableModelRouter = TableModelRouter(
        registry: providerRegistry,
        hermesDefaultModel: services.hermesDefaultModel
    )
    // HER-252 — wrap the static table with a user-preference-aware router
    // so a user's primary (provider, model) + fallback chain take
    // precedence on every chat / query / kb-compile call. Absent any
    // user preference row, the table is consulted exactly as before.
    let legacyModelRouter: any ModelRouter = UserPreferenceModelRouter(
        preferences: userLLMPreferenceRepo,
        fallback: tableModelRouter,
        logger: routingLogger
    )
    let routerTelemetry = RouterTelemetryService(
        fluent: services.fluent,
        logger: Logger(label: "lv.cerberus.telemetry")
    )
    let routerProfileRepo = RouterProfileRepository(
        fluent: services.fluent,
        legacyPreferences: userLLMPreferenceRepo,
        managedModel: services.hermesDefaultManagedModel,
        logger: Logger(label: "lv.cerberus.profiles")
    )
    let cerberusExecutionMode = reader.string(
        forKey: ConfigKey("cerberus.executionMode"),
        default: "active"
    ).lowercased()
    let cerberusEnsemblesEnabled = reader.bool(
        forKey: ConfigKey("cerberus.ensemblesEnabled"),
        default: false
    )
    // New name reflects all supported parallel strategies. The legacy flag
    // remains a one-release fallback for existing deployments.
    let cerberusParallelEnabled = reader.bool(
        forKey: ConfigKey("cerberus.parallelEnabled"),
        default: cerberusEnsemblesEnabled
    )
    let cerberusRouter: any ModelRouter = CerberusModelRouter(
        profiles: routerProfileRepo,
        fallback: legacyModelRouter,
        budget: routerTelemetry,
        ensemblesEnabled: cerberusParallelEnabled,
        logger: routingLogger,
        credentials: userCredentialStore,
        registry: providerRegistry
    )
    let modelRouter: any ModelRouter = cerberusExecutionMode == "active"
        ? cerberusRouter
        : legacyModelRouter
    let usageMeterService = UsageMeterService(
        fluent: services.fluent,
        freeMtokDaily: services.usageFreeMtokDaily,
        perSkillMtokDaily: services.usagePerSkillMtokDaily,
        degradeModel: services.usageDegradeModel,
        logger: Logger(label: "lv.usage-meter")
    )

    let parallelStore = ParallelExecutionStore(
        fluent: services.fluent,
        logger: Logger(label: "lv.cerberus.parallel.store")
    )
    let parallelExecutor = ParallelExecutor(
        registry: providerRegistry,
        logger: Logger(label: "lv.cerberus.parallel"),
        store: parallelStore
    )
    let routedTransport = RoutedLLMTransport(
        registry: providerRegistry,
        router: modelRouter,
        logger: routingLogger,
        usageMeter: usageMeterService,
        failoverLogger: providerFailoverLogger,
        routerTelemetry: routerTelemetry,
        parallelExecutor: parallelExecutor
    )

    // Cron bridge — assembled now that `routedTransport` exists (the NL→spec
    // classifier needs it). Deps were captured from the secret branch.
    if let cronDocker, let cronContainerManager, let cronSSRF, let secretBoxRef {
        cronBridgeService = CronBridgeService(
            docker: cronDocker,
            containerManager: cronContainerManager,
            fluent: services.fluent,
            secretBox: secretBoxRef,
            ssrfGuard: cronSSRF,
            httpClient: BYOHTTP.httpClient,
            classifier: JobIntentClassifier(transport: routedTransport, model: services.hermesDefaultModel),
            logger: Logger(label: "lv.cron-bridge")
        )
    }

    // HER-200 — use the routed transport for the user-facing chat
    // endpoint so model-based routing + failover apply to LLM calls.
    let llmService = RoutedHermesLLMService(
        transport: routedTransport,
        defaultModel: services.hermesDefaultModel,
        logger: Logger(label: "lv.llm"),
        preferences: userLLMPreferenceRepo
    )
    // LuminaVault-owned self-improvement. Hermes remains a REST-only
    // inference dependency; curator state and tenant isolation live here.
    let selfImprovementLLM = DefaultHermesLLMService(
        baseURL: hermesURL,
        session: .shared,
        defaultModel: services.hermesDefaultModel,
        logger: Logger(label: "lv.self-improvement.llm"),
        apiKey: services.hermesAPIKey
    )
    let selfImprovementService = SelfImprovementService(
        fluent: services.fluent,
        catalog: skillCatalog,
        vaultPaths: vaultPaths,
        soulService: soulService,
        llm: selfImprovementLLM,
        capabilities: hermesCapabilitiesService,
        economyModel: reader.string(
            forKey: ConfigKey("selfImprovement.economyModel"),
            default: services.usageDegradeModel
        ),
        mainModel: services.hermesDefaultModel,
        globallyEnabled: reader.bool(
            forKey: ConfigKey("selfImprovement.enabled"),
            default: true
        ),
        logger: Logger(label: "lv.self-improvement")
    )
    if fluentEnabled, lvEnvironment != "test" {
        managedServices.append(SelfImprovementScheduler(
            service: selfImprovementService,
            logger: Logger(label: "lv.self-improvement.scheduler")
        ))
    }
    let selfImprovementGroup = router.group("/v1/me/improvement")
        .add(middleware: jwtAuthenticator)
    SelfImprovementController(service: selfImprovementService).addRoutes(to: selfImprovementGroup)
    // HER-240 / spec ticket #4 — pre-enrich chat messages with <context>
    // blocks for any URLs the user pasted. Reuses URLEnrichmentService's
    // lightweight enrichURL helper (no DB/disk side effects).
    //
    // HER-240 / spec ticket #3 — jina.ai tier-2 post-processor (fetches the
    // full page body when the primary OG enricher is shallow). Always wired:
    // r.jina.ai's reader works KEYLESS (the key is optional, only lifts rate
    // limits), so capture/import links get real article bodies — and therefore
    // real memories — even with no `JINA_API_KEY` configured. Previously this
    // was nil without a key, so every link enriched to title-only (~250 bytes)
    // and compiled to zero memories.
    let jinaEnricher: JinaEnricher? = JinaEnricher(
        session: URLSession(configuration: .ephemeral),
        apiKey: services.jinaAPIKey.isEmpty ? nil : services.jinaAPIKey,
        logger: Logger(label: "lv.capture.jina")
    )
    // HER-54 (Slice 1) — capture-hook engine. First-party hooks only; resolved
    // by `binding` exactly like connectors. The dispatcher is failure-isolated
    // so an installed hook can never break a capture.
    let captureHookDispatcher = CaptureHookDispatcher(
        fluent: services.fluent,
        registry: CaptureHookRegistry(hooks: [
            ReadingTimeHook(),
        ]),
        logger: Logger(label: "lv.capture.hooks")
    )
    let urlEnrichmentService = URLEnrichmentService(
        vaultPaths: vaultPaths,
        fluent: services.fluent,
        logger: Logger(label: "lv.capture"),
        jinaEnricher: jinaEnricher,
        captureHooks: captureHookDispatcher
    )
    let chatURLPreEnricher = ChatURLPreEnricher(
        urlEnrichmentService: urlEnrichmentService,
        logger: Logger(label: "lv.llm.chat-url-preenricher")
    )
    let llmController = LLMController(
        service: llmService,
        telemetry: llmTelemetry,
        notificationService: pushService,
        achievements: achievementsWorker,
        usageMeter: usageMeterService,
        urlPreEnricher: chatURLPreEnricher
    )
    // HER-172 ContextRouter — feature-gated by `users.context_routing`.
    // Constructed unconditionally; the middleware short-circuits when the
    // flag is false OR the entitlement check fails, so wiring it here
    // does not affect Free/Trial users in any way.
    let contextRouterSelectorFactory: @Sendable (UUID, String) -> any ContextRouterSelector = { tenantID, _ in
        DefaultContextRouterSelector(
            transport: routedTransport,
            model: services.hermesDefaultModel,
            sessionKey: tenantID.uuidString,
            logger: Logger(label: "lv.context-router")
        )
    }
    let contextRouterMiddleware = ContextRouterMiddleware(
        catalog: skillCatalog,
        selectorFactory: contextRouterSelectorFactory,
        entitlement: { user in
            EntitlementChecker.entitled(
                tier: UserTier(rawValue: user.tier) ?? .trial,
                override: TierOverride(rawValue: user.tierOverride) ?? .none,
                for: .privacyContextRouter
            )
        },
        logger: Logger(label: "lv.context-router")
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
            logger: transcribeLogger
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
            durationSeconds: reader.double(forKey: "transcribe.stub.durationSeconds", default: 30)
        ))
    }
    let transcribeRegistry = TranscribeProviderRegistry.from(
        reader: reader,
        adapters: transcribeAdapters,
        logger: transcribeLogger
    )
    managedServices.append(transcribeRegistry)
    let transcribeService = TranscribeService(
        registry: transcribeRegistry,
        usageMeter: usageMeterService,
        logger: transcribeLogger
    )
    let transcribeController = TranscribeController(
        service: transcribeService,
        logger: transcribeLogger
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
            logger: visionEmbedLogger
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
            sourceHeight: reader.int(forKey: "vision.embed.stub.sourceHeight", default: 768)
        ))
    }
    let visionEmbedRegistry = VisionEmbedProviderRegistry.from(
        reader: reader,
        adapters: visionEmbedAdapters,
        logger: visionEmbedLogger
    )
    managedServices.append(visionEmbedRegistry)
    let visionEmbedService = VisionEmbedService(
        registry: visionEmbedRegistry,
        fluent: services.fluent,
        usageMeter: usageMeterService,
        logger: visionEmbedLogger,
        // Pinned to the `memories.embedding` column width (1536, M07).
        targetDim: 1536
    )
    let visionEmbedController = VisionEmbedController(
        service: visionEmbedService,
        logger: visionEmbedLogger
    )
    let visionEmbedGroup = router.group("/v1/vision")
        .add(middleware: jwtAuthenticator)
        .add(middleware: EntitlementMiddleware(requires: .memoryQuery, enforcementEnabled: services.billingEnforcementEnabled))
        .add(middleware: RateLimitMiddleware(policy: .visionEmbedByUserPerMinute, storage: rateLimitStorage))
        .add(middleware: RateLimitMiddleware(policy: .visionEmbedByUserDaily, storage: rateLimitStorage))
    visionEmbedController.addRoutes(to: visionEmbedGroup)

    // HER-206 — GET /v1/me/today widget + daily-review aggregator.
    // Cache + EventBus listener live in `MeTodayCache` (a Service);
    // it invalidates entries within 1s of memory_upserted /
    // achievement_unlocked events for the publishing tenant.
    let meTodayLogger = Logger(label: "lv.me.today")
    let meTodayCache = MeTodayCache(ttl: 300, eventBus: eventBus, logger: meTodayLogger)
    managedServices.append(meTodayCache)
    let meTodayService = MeTodayService(
        fluent: services.fluent,
        memories: MemoryRepository(fluent: services.fluent),
        achievements: achievementsService,
        spaces: SpacesService(fluent: services.fluent, vaultPaths: vaultPaths, logger: Logger(label: "lv.spaces.metoday")),
        catalog: .current,
        logger: meTodayLogger
    )
    let meTodayController = MeTodayController(
        service: meTodayService,
        cache: meTodayCache,
        logger: meTodayLogger
    )
    // No EntitlementMiddleware — read of own data, mirrors HER-202
    // `/v1/health` precedent. JWT + per-user rate-limit only.
    let meTodayGroup = router.group("/v1/me")
        .add(middleware: jwtAuthenticator)
        .add(middleware: RateLimitMiddleware(policy: .meTodayByUser, storage: rateLimitStorage))
    meTodayController.addRoutes(to: meTodayGroup)

    // HER-37 — GET /v1/me/suggestions. Static list at scaffold; iterates to
    // per-user dynamic generation in HER-37a. Sibling of `/v1/me/today` —
    // JWT-only, no entitlement gate (read of own data).
    let suggestionsGroup = router.group("/v1/me")
        .add(middleware: jwtAuthenticator)
        .add(middleware: RateLimitMiddleware(policy: .meTodayByUser, storage: rateLimitStorage))
    SuggestionsController().addRoutes(to: suggestionsGroup)

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
            logger: Logger(label: "lv.tts.openai")
        )
        let routedTTSTransport = RoutedTTSTransport(
            adapter: ttsAdapter,
            defaultModel: services.ttsDefaultModel,
            logger: Logger(label: "lv.tts"),
            usageMeter: usageMeterService
        )
        let ttsController = TTSController(
            transport: routedTTSTransport,
            telemetry: RouteTelemetry(labelPrefix: "tts", logger: Logger(label: "lv.tts")),
            logger: Logger(label: "lv.tts")
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

    // HER-134 — text-embedding registry. Selectable provider via
    // `EMBEDDING_PROVIDER` env (openai|hermesLocal|nomic|deterministic),
    // optional fallback chain via `EMBEDDING_FALLBACK_CHAIN`, monthly per-
    // tenant token cap via `EMBEDDING_MONTHLY_TOKEN_CAP_DEFAULT`. The
    // returned `active` is already wrapped in the usage tracker + fallback
    // chain so consumers keep depending on the bare `EmbeddingService`
    // protocol. LocalHermes handle resolver is a no-op for the scaffold —
    // it falls through with `.endpointMissing` until follow-up ticket
    // wires the per-tenant container manager into this scope.
    let embeddingRegistry = EmbeddingProviderRegistry.bootstrap(
        reader: reader,
        fluent: services.fluent,
        hermesHandleResolver: localHermesHandleResolver,
        logger: Logger(label: "lv.embedding.registry")
    )
    // HER-43 Slice 4 — when a master secret is set, wrap the global embedding
    // service so a tenant who installed the "byok-embeddings" memory plugin is
    // routed through their own key, using the SAME active provider-kind + model
    // (identical vector space → no re-embedding). Falls through to global for
    // everyone else, and BYO is only buildable for keyable kinds (openai/nomic).
    let embeddingService: any EmbeddingService
    if let secretBox = secretBoxRef {
        let activeKind = embeddingRegistry.activeKind
        let openaiBaseRaw = reader.string(forKey: "llm.provider.openai.baseURL", default: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let openaiBase = URL(string: openaiBaseRaw) ?? OpenAIEmbeddingService.defaultBaseURL
        let makeKeyed: @Sendable (String) -> (any EmbeddingService)? = { apiKey in
            switch activeKind {
            case .openai:
                OpenAIEmbeddingService(apiKey: apiKey, baseURL: openaiBase, logger: Logger(label: "lv.embedding.openai.byok"))
            case .nomic:
                NomicEmbeddingService(apiKey: apiKey, logger: Logger(label: "lv.embedding.nomic.byok"))
            case .hermesLocal, .deterministic:
                nil
            }
        }
        let resolver = PerTenantEmbeddingResolver(
            fluent: services.fluent,
            secretBox: secretBox,
            logger: Logger(label: "lv.embedding.byok"),
            makeKeyedService: makeKeyed
        )
        embeddingService = TenantAwareEmbeddingService(global: embeddingRegistry.active, resolver: resolver)
    } else {
        embeddingService = embeddingRegistry.active
    }

    // Memory agent (tool-calling Hermes loop) + protected routes.
    let vaultAccessService = VaultAccessService(fluent: services.fluent)
    let vaultActivityPublisher = VaultActivityPublisher()
    let vaultActivityRecorder = VaultActivityRecorder(fluent: services.fluent, publisher: vaultActivityPublisher)
    let memoryService = HermesMemoryService(
        transport: routedTransport,
        memories: MemoryRepository(fluent: services.fluent),
        embeddings: embeddingService,
        defaultModel: services.hermesDefaultModel,
        eventBus: eventBus,
        logger: Logger(label: "lv.memory"),
        vaultMapEnabled: vaultMapToolEnabled,
        retrievalTelemetry: retrievalTelemetryWorker
    )
    let memoryController = MemoryController(
        vaultAccess: vaultAccessService,
        service: memoryService,
        repository: MemoryRepository(fluent: services.fluent),
        embeddings: embeddingService,
        achievements: achievementsWorker,
        graphService: MemoryGraphService(fluent: services.fluent),
        rejectListRepository: KBCompileRejectListRepository(fluent: services.fluent),
        hybridExecutionEnabled: reader.string(forKey: "hybridExecution.enabled", default: "true").lowercased() == "true",
        eventBus: eventBus
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

    // Evidence-backed claim/entity/event graph. Kept on a separate contract
    // so older clients continue decoding the legacy memory graph unchanged.
    let knowledgeController = KnowledgeGraphController(
        service: KnowledgeGraphService(
            fluent: services.fluent,
            transport: routedTransport,
            model: services.hermesDefaultModel,
            logger: Logger(label: "lv.knowledge.reasoning")
        ),
        vaultAccess: vaultAccessService
    )
    let knowledgeGroup = router.group("/v1/knowledge")
        .add(middleware: jwtAuthenticator)
        .add(middleware: EntitlementMiddleware(requires: .memoryQuery, enforcementEnabled: services.billingEnforcementEnabled))
        .add(middleware: RateLimitMiddleware(policy: .captureByUser, storage: rateLimitStorage))
    knowledgeController.addRoutes(to: knowledgeGroup)

    // HER-149: URL capture with async enrichment (YouTube oEmbed, X scraper, GenericOG).
    // Note: `urlEnrichmentService` + `jinaEnricher` are constructed earlier
    // (above `llmController`) so that `ChatURLPreEnricher` can share the
    // same instance for HER-240 spec ticket #4 chat pre-enrichment.
    // HER-274 — shared by `CaptureController` (Safari share extension)
    // and `ConversationController` (chat auto-save-link post-processor).
    // Same vault file shape and enrichment pipeline either way.
    //
    // HER-274 follow-up — this is the embedding-aware enrichment instance.
    // Unlike `urlEnrichmentService` (the chat pre-enricher copy, which only
    // calls the side-effect-free `enrichURL`), the capture path persists, so
    // it gets `embeddings` + `memories` wired: every saved link is embedded
    // into the recall index and surfaces in future chat grounding. Built here
    // (not above `llmController`) because `embeddingService` isn't ready yet
    // at that point. Idempotent on `source_vault_file_id`.
    let capturingEnrichmentService = URLEnrichmentService(
        vaultPaths: vaultPaths,
        fluent: services.fluent,
        logger: Logger(label: "lv.capture"),
        jinaEnricher: jinaEnricher,
        captureHooks: captureHookDispatcher,
        embeddings: embeddingService,
        memories: MemoryRepository(fluent: services.fluent)
    )
    let linkCaptureService = LinkCaptureService(
        vaultPaths: vaultPaths,
        fluent: services.fluent,
        eventBus: eventBus,
        achievements: achievementsWorker,
        enrichmentService: capturingEnrichmentService,
        logger: Logger(label: "lv.capture")
    )
    let captureController = CaptureController(service: linkCaptureService)
    // HER-274 — global kill-switch for the chat auto-save-link
    // post-processor. Defaults ON. Per-user opt-out lives on the
    // `users.auto_save_links` column (PATCH /v1/me/privacy).
    let autoSaveLinksEnabled = reader.string(forKey: "autoSaveLinks.enabled", default: "true").lowercased() == "true"
    let captureGroup = router.group("/v1/capture")
        .add(middleware: jwtAuthenticator)
        .add(middleware: EntitlementMiddleware(requires: .capture, enforcementEnabled: services.billingEnforcementEnabled))
        .add(middleware: RateLimitMiddleware(policy: .captureByUser, storage: rateLimitStorage))
    captureController.addRoutes(to: captureGroup)

    // Query (natural-language semantic search) — protected.
    // HER-37 — streaming counterpart at POST /v1/query/stream hits the
    // central Hermes gateway directly (routed/Gemini streaming is out of
    // scope). Bypasses the routing layer; falls back to non-streaming
    // `/v1/query` via the existing agent loop.
    // Idle (inter-chunk) timeout for Hermes SSE. Bounds silence between body
    // chunks so a stalled upstream fails fast instead of hanging until the
    // client's request timeout. Tune via HERMES_STREAM_IDLE_TIMEOUT.
    let hermesStreamIdleSeconds = Int64(reader.string(forKey: "hermes.streamIdleTimeout", default: "60")) ?? 60
    let queryStreamService = DefaultHermesLLMStreamService(
        // SSRF hardening: no-redirect client so a BYO endpoint can't 30x the
        // streamed request to an internal host post-validation.
        baseURL: hermesURL,
        httpClient: BYOHTTP.httpClient,
        defaultModel: services.hermesDefaultModel,
        logger: Logger(label: "lv.query.stream"),
        apiKey: services.hermesAPIKey,
        streamIdleTimeout: .seconds(hermesStreamIdleSeconds)
    )
    // HER-37 Slice C — single FollowUpGenerator instance shared by the
    // Query + Conversation controllers. Reuses the routed transport so
    // Gemini/Grok/BYO routing applies to the follow-up call too.
    let followUpGenerator = FollowUpGenerator(
        transport: routedTransport,
        defaultModel: services.hermesDefaultModel,
        logger: Logger(label: "lv.followups")
    )
    let queryController = QueryController(
        service: memoryService,
        achievements: achievementsWorker,
        memories: MemoryRepository(fluent: services.fluent),
        embeddings: embeddingService,
        streamService: queryStreamService,
        followUpGenerator: followUpGenerator,
        defaultModel: services.hermesDefaultModel,
        retrievalTelemetry: retrievalTelemetryWorker,
        llmPreferences: userLLMPreferenceRepo
    )
    // HER-223 — query fires Hermes calls under the hood via memoryService.
    let queryBase = router.group("/v1/query").add(middleware: jwtAuthenticator)
    let queryWithByo = byoHermesMiddleware.map { queryBase.add(middleware: $0) } ?? queryBase
    let queryGroup = queryWithByo
        .add(middleware: RateLimitMiddleware(policy: .queryByUser, storage: rateLimitStorage))
        .add(middleware: EntitlementMiddleware(requires: .memoryQuery, enforcementEnabled: services.billingEnforcementEnabled))
    queryController.addRoutes(to: queryGroup)

    // Per-tenant BYOK streaming. When a tenant is in BYOK mode with a
    // native-streaming provider (Gemini today), route the chat stream
    // straight to their provider; otherwise fall through to the managed
    // Hermes gateway (`queryStreamService`). Only built when the SecretBox
    // exists (same gate as the credential store) — without it BYOK keys
    // can't be decrypted, so we keep the unchanged managed behaviour.
    let conversationStreamService: any HermesLLMStreamService = RoutedHermesLLMStreamService(
        fallback: queryStreamService,
        transport: routedTransport,
        preferences: userLLMPreferenceRepo,
        logger: Logger(label: "lv.chat.stream.routed"),
        router: modelRouter
    )

    // HER-37 Slice B — multi-turn chat persistence. Reuses the same
    // retrieval pipeline as /v1/query/stream. BYO Hermes middleware is in
    // scope because managed turns hit the gateway.
    let conversationController = ConversationController(
        fluent: services.fluent,
        memories: MemoryRepository(fluent: services.fluent),
        embeddings: embeddingService,
        streamService: conversationStreamService,
        followUpGenerator: followUpGenerator,
        linkCapture: autoSaveLinksEnabled ? linkCaptureService : nil,
        parallelEnabled: cerberusParallelEnabled,
        hybridExecutionEnabled: reader.string(forKey: "hybridExecution.enabled", default: "true").lowercased() == "true",
        localExecutionToolBrokerEnabled: reader.string(
            forKey: "localExecution.toolBroker.enabled",
            default: "true"
        ).lowercased() == "true",
        defaultModel: services.hermesDefaultModel,
        logger: Logger(label: "lv.conversations"),
        vaultAccess: VaultAccessService(fluent: services.fluent),
        retrievalTelemetry: retrievalTelemetryWorker,
        selfImprovement: selfImprovementService,
        llmPreferences: userLLMPreferenceRepo
    )
    let conversationsBase = router.group("/v1/conversations").add(middleware: jwtAuthenticator)
    let conversationsWithByo = byoHermesMiddleware.map { conversationsBase.add(middleware: $0) } ?? conversationsBase
    // HER-273 — apply persona resolver AFTER auth + Hermes resolution
    // so the session-key prefix can pick up the resolved Hermes profile.
    let conversationsGroup = conversationsWithByo
        .add(middleware: hermesProfileMiddleware)
        .add(middleware: RateLimitMiddleware(policy: .conversationByUser, storage: rateLimitStorage))
        .add(middleware: EntitlementMiddleware(requires: .memoryQuery, enforcementEnabled: services.billingEnforcementEnabled))
    conversationController.addRoutes(to: conversationsGroup)

    // Usability layer — primary Chats inbox over the same persisted
    // conversation data plus backend-synced chat preferences.
    let chatExperienceController = ChatExperienceController(
        fluent: services.fluent,
        logger: Logger(label: "lv.chat.experience")
    )
    let chatGroup = router.group("/v1/chat")
        .add(middleware: jwtAuthenticator)
        .add(middleware: RateLimitMiddleware(policy: .conversationByUser, storage: rateLimitStorage))
    chatExperienceController.addInboxRoutes(to: chatGroup)
    let chatPreferencesGroup = router.group("/v1/me/chat-preferences")
        .add(middleware: jwtAuthenticator)
        .add(middleware: RateLimitMiddleware(policy: .settingsByUser, storage: rateLimitStorage))
    chatExperienceController.addPreferencesRoutes(to: chatPreferencesGroup)
    if reader.string(forKey: "hybridExecution.enabled", default: "true").lowercased() == "true" {
        let hybridPreferencesGroup = router.group("/v1/me/preferences/hybrid-execution")
            .add(middleware: jwtAuthenticator)
            .add(middleware: RateLimitMiddleware(policy: .settingsByUser, storage: rateLimitStorage))
        chatExperienceController.addHybridPreferencesRoutes(to: hybridPreferencesGroup)
    }

    // Memo generator (read-only agent loop → markdown synthesis → vault save).
    let memoGenerator = MemoGeneratorService(
        transport: routedTransport,
        memories: MemoryRepository(fluent: services.fluent),
        embeddings: embeddingService,
        vaultPaths: vaultPaths,
        fluent: services.fluent,
        defaultModel: services.hermesDefaultModel,
        logger: Logger(label: "lv.memo")
    )
    let memoController = MemoController(service: memoGenerator, fluent: services.fluent)
    // HER-223 — memo generator runs an agent loop with multiple Hermes calls.
    let memoBase = router.group("/v1/memos").add(middleware: jwtAuthenticator)
    let memoWithByo = byoHermesMiddleware.map { memoBase.add(middleware: $0) } ?? memoBase
    let memoGroup = memoWithByo
        .add(middleware: EntitlementMiddleware(requires: .memoGenerator, enforcementEnabled: services.billingEnforcementEnabled))
    memoController.addRoutes(to: memoGroup)

    // Spaces (user-defined organizing folders) — service is created early so
    // the vault-init handshake can seed default Spaces on first launch.
    let spacesService = SpacesService(
        fluent: services.fluent,
        vaultPaths: vaultPaths,
        logger: Logger(label: "lv.spaces")
    )

    // HER-234 — per-tenant partial HNSW index lifecycle. Pairs with M39's
    // baseline global HNSW + tsvector. `ensureIndex` fires once per tenant
    // on vault-init; `dropIndex` is wired into the account-deletion path
    // in a follow-up.
    let tenantVectorIndexService = TenantVectorIndexService(
        fluent: services.fluent,
        logger: Logger(label: "lv.vector.index")
    )

    // HER-35: VaultInitService owns the `POST /v1/vault/create` handshake.
    // It pulls together the existing SOUL bootstrap, default-Space seeding,
    // and the `users.vault_initialized` flip so the client can render a
    // clean "Create My Vault" gate before any other tab unlocks.
    let vaultInitService = VaultInitService(
        fluent: services.fluent,
        vaultPaths: vaultPaths,
        soulService: soulService,
        spacesService: spacesService,
        vectorIndexService: tenantVectorIndexService,
        logger: Logger(label: "lv.vault.init")
    )

    // Vault file upload (markdown + images) + init handshake — protected.
    let vaultController = VaultController(
        vaultPaths: vaultPaths,
        fluent: services.fluent,
        initService: vaultInitService,
        eventBus: eventBus,
        achievements: achievementsWorker,
        logger: Logger(label: "lv.vault"),
        memories: MemoryRepository(fluent: services.fluent),
        embeddings: embeddingService,
        vaultAccess: vaultAccessService
    )
    let vaultGroup = router.group("/v1/vault")
        .add(middleware: jwtAuthenticator)
        .add(middleware: IdempotencyMiddleware(fluent: services.fluent))
        .add(middleware: RateLimitMiddleware(policy: .vaultUploadByUser, storage: rateLimitStorage))
    vaultController.addRoutes(to: vaultGroup)

    // HER-35: vault init handshake — separate group so the heavy upload
    // rate-limit policy never blocks the "Create My Vault" call.
    let vaultInitGroup = router.group("/v1/vault")
        .add(middleware: jwtAuthenticator)
        .add(middleware: IdempotencyMiddleware(fluent: services.fluent))
    vaultController.addInitRoutes(to: vaultInitGroup)

    // HER-91: vault export — separate group so the heavier per-user limit
    // doesn't fight the upload limiter, and so exports never burn the
    // upload bucket.
    let vaultExportGroup = router.group("/v1/vault")
        .add(middleware: jwtAuthenticator)
        .add(middleware: RateLimitMiddleware(policy: .vaultExportByUser, storage: rateLimitStorage))
    vaultController.addExportRoute(to: vaultExportGroup)

    // memory-compile (write batch + Hermes learning loop) — protected.
    // HER-240 / spec ticket #2: legacy /v1/kb-compile route 308-redirects
    // to /v1/memory-compile (registered below) until iOS clients migrate.
    let memoryCompileProgressPublisher = WebSocketMemoryCompileProgressPublisher(
        connectionManager: ConnectionManager.shared,
        logger: Logger(label: "lv.memory-compile.progress")
    )
    let memoryCompileService = MemoryCompileService(
        vaultPaths: vaultPaths,
        transport: kbCompileTransportOverride ?? routedTransport,
        memories: MemoryRepository(fluent: services.fluent),
        embeddings: embeddingService,
        defaultModel: services.hermesDefaultModel,
        logger: Logger(label: "lv.memory-compile"),
        progress: memoryCompileProgressPublisher
    )
    let memoryCompileController = MemoryCompileController(
        service: memoryCompileService,
        fluent: services.fluent,
        achievements: achievementsWorker,
        progress: memoryCompileProgressPublisher,
        usageMetrics: UsageMetricsService(fluent: services.fluent),
        logger: Logger(label: "lv.memory-compile.controller")
    )
    // HER-293 — `GET /v1/memory-compile/pending` is a cheap COUNT(*) probe
    // behind the iOS "Sync & Learn" disabled-state UX (HER-108). Registered
    // on a jwt-only group so polling on screen-focus does NOT consume the
    // memory-compile rate limit or hit the entitlement gate the heavy POST
    // sits behind.
    let memoryCompilePendingGroup = router.group("/v1/memory-compile")
        .add(middleware: jwtAuthenticator)
    memoryCompileController.addPendingRoutes(to: memoryCompilePendingGroup)

    // HER-223 — memory-compile fires the heaviest Hermes traffic; must
    // route to the user's gateway when one is configured.
    let memoryCompileBase = router.group("/v1/memory-compile")
        .add(middleware: jwtAuthenticator)
        .add(middleware: IdempotencyMiddleware(fluent: services.fluent))
    let memoryCompileWithByo = byoHermesMiddleware.map { memoryCompileBase.add(middleware: $0) } ?? memoryCompileBase
    let memoryCompileGroup = memoryCompileWithByo
        .add(middleware: EntitlementMiddleware(requires: .memoryCompile, enforcementEnabled: services.billingEnforcementEnabled))
        .add(middleware: RateLimitMiddleware(policy: .memoryCompileByUser, storage: rateLimitStorage))
    memoryCompileController.addCompileRoutes(to: memoryCompileGroup)

    // HER-240 / spec ticket #2: legacy aliases. Permanent redirect to the
    // canonical paths. Logged at warn level so we can find stragglers
    // before retiring the alias next milestone.
    let kbCompileAliasLogger = Logger(label: "lv.memory-compile.legacy-alias")
    router.post("/v1/kb-compile") { _, _ -> Response in
        kbCompileAliasLogger.warning("legacy POST /v1/kb-compile hit — caller should migrate to /v1/memory-compile")
        return Response(
            status: .permanentRedirect,
            headers: [.location: "/v1/memory-compile"]
        )
    }
    router.get("/v1/kb-compile/pending") { _, _ -> Response in
        kbCompileAliasLogger.warning("legacy GET /v1/kb-compile/pending hit — caller should migrate to /v1/memory-compile/pending")
        return Response(
            status: .permanentRedirect,
            headers: [.location: "/v1/memory-compile/pending"]
        )
    }

    // Spaces routes — service is constructed alongside `vaultInitService`
    // above so first-run vault create can seed defaults.
    let spacesController = SpacesController(
        service: spacesService,
        vaultAccess: vaultAccessService,
        activity: vaultActivityRecorder
    )
    let spacesGroup = router.group("/v1/spaces").add(middleware: jwtAuthenticator)
    spacesController.addRoutes(to: spacesGroup)

    // Team/shared-vault control plane. Resource endpoints remain backwards
    // compatible: no X-Vault-ID means the caller's personal vault.
    let teamController = TeamController(
        fluent: services.fluent,
        vaultPaths: vaultPaths,
        access: vaultAccessService,
        invitationSender: makeTeamInvitationSender(
            kind: services.emailKind,
            apiKey: services.emailResendAPIKey,
            fromAddress: services.emailFromAddress,
            replyTo: services.emailReplyTo,
            baseURL: URL(string: services.teamInviteBaseURL) ?? URL(string: "http://localhost:5173")!,
            logger: Logger(label: "lv.team-invitations")
        ),
        activityPublisher: vaultActivityPublisher
    )
    let teamsGroup = router.group("/v1/teams")
        .add(middleware: jwtAuthenticator)
        .add(middleware: RateLimitMiddleware(policy: .settingsByUser, storage: rateLimitStorage))
    teamController.addRoutes(to: teamsGroup)
    let sharedVaultsGroup = router.group("/v1/vaults")
        .add(middleware: jwtAuthenticator)
        .add(middleware: RateLimitMiddleware(policy: .settingsByUser, storage: rateLimitStorage))
    teamController.addVaultRoutes(to: sharedVaultsGroup)
    let invitationsGroup = router.group("/v1/team-invitations")
        .add(middleware: jwtAuthenticator)
        .add(middleware: RateLimitMiddleware(policy: .settingsByUser, storage: rateLimitStorage))
    teamController.addInvitationRoutes(to: invitationsGroup)

    // "Feed Your Brain" — bulk import: stage links into the `imported` inbox,
    // Smart-Import categorize into Spaces, approve → file + scoped compile.
    let importController = ImportController(
        service: ImportService(
            fluent: services.fluent,
            linkCapture: linkCaptureService,
            spaces: spacesService,
            vaultPaths: vaultPaths,
            memoryCompile: memoryCompileService,
            urlEnrich: urlEnrichmentService,
            logger: Logger(label: "lv.import")
        ),
        categorizer: ImportCategorizationService(
            fluent: services.fluent,
            transport: routedTransport,
            vaultPaths: vaultPaths,
            defaultModel: services.hermesDefaultModel,
            logger: Logger(label: "lv.import.categorize")
        )
    )
    let importGroup = router.group("/v1/import").add(middleware: jwtAuthenticator)
    importController.addRoutes(to: importGroup)

    // Durable multimodal ingestion. The original is written to the same vault
    // Hermes sees; Hermes returns structured analysis and the server owns the
    // resulting source-linked memory and processing status.
    let ingestionCapabilitiesService = hermesCapabilitiesService
    let ingestionPublicBaseURLRaw = reader.string(forKey: "ingestion.publicBaseUrl", default: "")
    let ingestionPublicBaseURL = ingestionPublicBaseURLRaw.isEmpty ? nil : URL(string: ingestionPublicBaseURLRaw)
    if !ingestionPublicBaseURLRaw.isEmpty, ingestionPublicBaseURL == nil {
        fatalError("INGESTION_PUBLIC_BASE_URL must be an absolute URL")
    }
    if lvEnvironment != "dev", let ingestionPublicBaseURL, ingestionPublicBaseURL.scheme != "https" {
        fatalError("INGESTION_PUBLIC_BASE_URL must use HTTPS outside development")
    }
    let multimodalIngestionService = MultimodalIngestionService(
        fluent: services.fluent,
        vaultPaths: vaultPaths,
        linkCapture: linkCaptureService,
        processor: HermesMultimodalProcessor(
            chatTransport: routedTransport,
            ingestionTransport: URLSessionHermesIngestionTransport(
                defaultBaseURL: hermesURL,
                defaultAuthHeader: services.hermesAPIKey.isEmpty ? nil : "Bearer \(services.hermesAPIKey)",
                endpointResolver: hermesEndpointResolver,
                session: BYOHTTP.session,
                logger: Logger(label: "lv.ingestion.hermes")
            ),
            model: services.hermesDefaultModel
        ),
        memories: MemoryRepository(fluent: services.fluent),
        embeddings: embeddingService,
        push: pushService,
        logger: Logger(label: "lv.ingestion"),
        ingestionCapabilities: { tenantID in
            guard let ingestionCapabilitiesService else { return .managedDefault }
            return await ingestionCapabilitiesService.capabilities(tenantID: tenantID).capabilities
        },
        publicBaseURL: ingestionPublicBaseURL
    )
    let ingestionController = MultimodalIngestionController(service: multimodalIngestionService, vaultAccess: vaultAccessService)
    ingestionController.addPublicSourceRoute(to: router)
    let ingestionGroup = router.group("/v1/ingestions")
        .add(middleware: jwtAuthenticator)
        .add(middleware: RateLimitMiddleware(policy: .ingestionUploadByUser, storage: rateLimitStorage))
    ingestionController.addRoutes(to: ingestionGroup)
    if fluentEnabled, lvEnvironment != "test" {
        managedServices.append(MultimodalIngestionWorker(service: multimodalIngestionService))
    }

    // Vault import bridge — bulk-ingest a user's Hermes/Obsidian markdown vault
    // into LuminaVault (vault_files + memories + embeddings + Space) so chat
    // grounding + the Brain graph use it. Mounted on the same JWT group.
    let vaultImportController = VaultImportController(
        ingest: VaultIngestService(
            fluent: services.fluent,
            vaultPaths: vaultPaths,
            spaces: spacesService,
            memories: MemoryRepository(fluent: services.fluent),
            embeddings: embeddingService,
            logger: Logger(label: "lv.import.vault")
        )
    )
    vaultImportController.addRoutes(to: importGroup)

    // HER-43 (Slice 1) — /v1/plugins (declarative plugin foundation). Mounted
    // only when the master secret is set: install config (e.g. a connector API
    // token) is sealed at rest via the same SecretBox as BYO Hermes. Connector
    // syncs reuse the import pipeline above.
    if let secretBox = secretBoxRef {
        let pluginService = PluginService(
            fluent: services.fluent,
            secretBox: secretBox,
            importService: ImportService(
                fluent: services.fluent,
                linkCapture: linkCaptureService,
                spaces: spacesService,
                vaultPaths: vaultPaths,
                memoryCompile: memoryCompileService,
                urlEnrich: urlEnrichmentService,
                logger: Logger(label: "lv.plugins.import")
            ),
            connectors: ConnectorRegistry(connectors: [
                ReadwiseConnector(
                    http: URLSessionConnectorHTTPClient(),
                    logger: Logger(label: "lv.plugins.readwise")
                ),
                RaindropConnector(
                    http: URLSessionConnectorHTTPClient(),
                    logger: Logger(label: "lv.plugins.raindrop")
                ),
                RSSConnector(
                    http: URLSessionConnectorHTTPClient(),
                    logger: Logger(label: "lv.plugins.rss")
                ),
            ]),
            skillCatalog: skillCatalog,
            hermesSkills: HermesSkillsClient(logger: Logger(label: "lv.plugins.hermes-skills")),
            logger: Logger(label: "lv.plugins")
        )
        // `byoHermesMiddleware` is added when available so `GET /hermes-skills`
        // can read the tenant's resolved Hermes base URL + auth from
        // `ctx.hermesResolution`; without it that route returns an empty list.
        let pluginsBase = router.group("/v1/plugins")
            .add(middleware: jwtAuthenticator)
            .add(middleware: RateLimitMiddleware(policy: .settingsByUser, storage: rateLimitStorage))
        let pluginsGroup = byoHermesMiddleware.map { pluginsBase.add(middleware: $0) } ?? pluginsBase
        PluginController(service: pluginService).addRoutes(to: pluginsGroup)
        let pluginRunner: any PluginRunnerClienting = if let url = URL(string: services.pluginRunnerURL) {
            PluginRunnerClient(baseURL: url, token: services.pluginRunnerToken, logger: Logger(label: "lv.plugin-runner"))
        } else {
            DisabledPluginRunnerClient()
        }
        let marketplaceService = MarketplaceService(
            fluent: services.fluent,
            logger: Logger(label: "lv.marketplace"),
            runner: pluginRunner,
            capabilityBroker: MarketplaceCapabilityBroker(
                fluent: services.fluent,
                vaultPaths: VaultPathService(rootPath: services.vaultRootPath),
                logger: Logger(label: "lv.marketplace-capabilities")
            ),
            artifactRoot: services.pluginArtifactRoot,
            artifactSigningKey: services.pluginArtifactSigningKey
        )
        let marketplaceGroup = router.group("/v1/marketplace")
            .add(middleware: jwtAuthenticator)
            .add(middleware: RateLimitMiddleware(policy: .settingsByUser, storage: rateLimitStorage))
        MarketplaceController(marketplace: marketplaceService, plugins: pluginService)
            .addRoutes(to: marketplaceGroup)
        // HER-43 Slice 3b — hub skill install/uninstall, mounted on the same
        // tenant-JWT group. Only when a per-tenant container manager exists.
        if let hubSkillsService {
            HermesHubSkillsController(service: hubSkillsService).addRoutes(to: pluginsGroup)
        }
        if let cronBridgeService {
            let cronGroup = router.group("/v1/me/hermes/cron").add(middleware: jwtAuthenticator)
            CronBridgeController(service: cronBridgeService).addRoutes(to: cronGroup)
        }
    }

    // SOUL.md CRUD (HER-85) — protected; per-user rate limited.
    let soulController = SoulController(
        service: soulService,
        telemetry: soulTelemetry,
        achievements: achievementsWorker,
        capabilities: hermesCapabilitiesService
    )
    let soulGroup = router.group("/v1/soul")
        .add(middleware: jwtAuthenticator)
        .add(middleware: RateLimitMiddleware(policy: .soulByUser, storage: rateLimitStorage))
    soulController.addRoutes(to: soulGroup)

    // HER-196 — achievements read surface. Catalog (code-defined) joined to
    // per-tenant progress rows. Writes happen fire-and-forget from the
    // hot-paths above; this group is GET-only.
    let achievementsController = AchievementsController(
        service: achievementsService,
        logger: Logger(label: "lv.achievements")
    )
    let achievementsGroup = router.group("/v1/achievements")
        .add(middleware: jwtAuthenticator)
        .add(middleware: RateLimitMiddleware(policy: .achievementsByUser, storage: rateLimitStorage))
    achievementsController.addRoutes(to: achievementsGroup)

    // HER-244 — OS Shell Home/Dashboard surface. Aggregated counters,
    // tasks list, insights list. Tasks + Insights are empty-list stubs
    // until HER-246 / HER-248 land their data layers.
    let dashboardController = DashboardController(
        fluent: services.fluent,
        logger: Logger(label: "lv.dashboard"),
        managedModel: services.hermesDefaultManagedModel
    )
    let dashboardGroup = router.group("/v1/dashboard").add(middleware: jwtAuthenticator)
    dashboardController.addRoutes(to: dashboardGroup)

    // HER-Insights — per-tenant usage analytics (the Home "Insights" card).
    let analyticsController = AnalyticsController(
        fluent: services.fluent,
        logger: Logger(label: "lv.analytics"),
        vaultAccess: VaultAccessService(fluent: services.fluent)
    )
    let analyticsGroup = router.group("/v1/analytics").add(middleware: jwtAuthenticator)
    analyticsController.addRoutes(to: analyticsGroup)
    if fluentEnabled, lvEnvironment != "test" {
        managedServices.append(AnalyticsMaintenanceService(fluent: services.fluent))
    }

    let tasksController = TasksController(fluent: services.fluent, logger: Logger(label: "lv.tasks"))
    let tasksGroup = router.group("/v1/tasks").add(middleware: jwtAuthenticator)
    tasksController.addRoutes(to: tasksGroup)

    // HER-37 Slice D — Postgres-backed insights surface (was a stub
    // under HER-244). The SynthesisWorker below populates `thisWeek`
    // synthesis + `patterns` rows on its hourly tick.
    let insightsController = InsightsController(
        fluent: services.fluent,
        logger: Logger(label: "lv.insights")
    )
    let insightsGroup = router.group("/v1/insights").add(middleware: jwtAuthenticator)
    insightsController.addRoutes(to: insightsGroup)

    // HER-273 — `/v1/profiles` CRUD for multi-Hermes-persona setups.
    // No SecretBox or BYO middleware: profiles are plaintext-by-design
    // (label + system prompt + skill enable list), tenant-scoped via
    // jwtAuthenticator. `X-Hermes-Profile` routing is layered on top
    // by `HermesProfileMiddleware` on the chat/memory groups.
    let profilesController = ProfilesController(
        fluent: services.fluent,
        logger: Logger(label: "lv.profiles")
    )
    let profilesGroup = router.group("/v1/profiles").add(middleware: jwtAuthenticator)
    profilesController.addRoutes(to: profilesGroup)

    // HER-Reminders — user-scheduled timed messages. Firing is owned by
    // ReminderScheduler (registered with the ServiceGroup below); this
    // controller is CRUD only.
    let remindersController = RemindersController(
        fluent: services.fluent,
        // HER-55 — chat→reminder detection reuses the routed LLM transport
        // + default model, mirroring JobsController's classifier wiring.
        classifier: ReminderIntentClassifier(transport: routedTransport, model: services.hermesDefaultModel),
        logger: Logger(label: "lv.reminders")
    )
    let remindersGroup = router.group("/v1/reminders").add(middleware: jwtAuthenticator)
    remindersController.addRoutes(to: remindersGroup)

    // HER-340 — Google Calendar (server-owned OAuth + sync). Requires
    // SecretBox to seal OAuth tokens; absent the master key the integration
    // is disabled (the connect endpoint would 503 anyway). The actual
    // Google client id/secret/redirect come from `oauth.googleCalendar.*`
    // and are surfaced as `isConfigured` to gate the connect flow + worker.
    if let secretBox = secretBoxRef {
        let calendarLogger = Logger(label: "lv.calendar")
        let calendarConfigured = !services.googleCalendarClientID.isEmpty
            && !services.googleCalendarClientSecret.isEmpty
            && !services.googleCalendarRedirectURI.isEmpty
        let calendarOAuthClient = GoogleCalendarOAuthClient(
            clientID: services.googleCalendarClientID,
            clientSecret: services.googleCalendarClientSecret,
            redirectURI: services.googleCalendarRedirectURI,
            logger: calendarLogger
        )
        let calendarTokenStore = CalendarTokenStore(
            fluent: services.fluent,
            secretBox: secretBox,
            oauth: calendarOAuthClient,
            logger: calendarLogger
        )
        let calendarSyncService = CalendarSyncService(
            fluent: services.fluent,
            tokenStore: calendarTokenStore,
            client: GoogleCalendarClient(logger: calendarLogger),
            logger: calendarLogger
        )
        let calendarOAuthService = GoogleCalendarOAuthService(
            fluent: services.fluent,
            oauth: calendarOAuthClient,
            tokenStore: calendarTokenStore,
            syncService: calendarSyncService,
            sessionStore: CalendarOAuthSessionStore(),
            isConfigured: calendarConfigured,
            logger: calendarLogger
        )
        let calendarController = CalendarController(
            fluent: services.fluent,
            oauthService: calendarOAuthService,
            syncService: calendarSyncService,
            logger: calendarLogger
        )
        let calendarGroup = router.group("/v1/calendar").add(middleware: jwtAuthenticator)
        calendarController.addRoutes(to: calendarGroup)
        calendarController.addPublicRoutes(to: router)
        if calendarConfigured {
            managedServices.append(CalendarSyncWorker(
                fluent: services.fluent,
                syncService: calendarSyncService,
                logger: calendarLogger
            ))
        }
    }

    // HER-Projects — todo containers (the Home "Projects" card). Note-todos
    // link to a project via `VaultFileMetadata.projectID`; this controller
    // owns the project rows + live per-project todo counts.
    let projectsController = ProjectsController(
        fluent: services.fluent,
        logger: Logger(label: "lv.projects")
    )
    let projectsGroup = router.group("/v1/projects").add(middleware: jwtAuthenticator)
    projectsController.addRoutes(to: projectsGroup)

    // HER-Notes/Todos merge — `/v1/todos` (TodoDTO) is backed by note metadata
    // (vault_files where metadata.isTodo): a todo IS a note, so the Todos API
    // and the note browser share one store. `projectID` links to the dedicated
    // Projects table above.
    let todosController = TodosController(
        fluent: services.fluent,
        vaultPaths: vaultPaths,
        memories: MemoryRepository(fluent: services.fluent),
        embeddings: embeddingService,
        logger: Logger(label: "lv.todos")
    )
    let todosGroup = router.group("/v1/todos").add(middleware: jwtAuthenticator)
    todosController.addRoutes(to: todosGroup)

    // HER-37 Slice D — synthesis worker. Off by default so local + CI
    // builds don't fire real Hermes traffic. Enable in production via
    // `SYNTHESIS_WORKER_ENABLED=true` env var.
    if reader.string(forKey: "synthesis.workerEnabled", default: "false").lowercased() == "true" {
        let synthesisWorker = SynthesisWorker(
            fluent: services.fluent,
            memories: MemoryRepository(fluent: services.fluent),
            transport: routedTransport,
            defaultModel: services.hermesDefaultModel,
            logger: Logger(label: "lv.synthesis")
        )
        managedServices.append(synthesisWorker)
    } else {
        routingLogger.info("synthesis worker disabled (set SYNTHESIS_WORKER_ENABLED=true to enable)")
    }

    // Retrieval leak report — weekly per-tenant roll-up of retrieval telemetry
    // (Sun 05:00 GMT). Pure DB read + summary write, no external traffic, on by
    // default outside test. Kill via `RETRIEVAL_LEAKREPORT_ENABLED=false`.
    if fluentEnabled, lvEnvironment != "test",
       reader.string(forKey: "retrieval.leakReport.enabled", default: "true").lowercased() != "false"
    {
        let surfaceInsight = reader.string(forKey: "retrieval.leakReport.surfaceInsight", default: "false").lowercased() == "true"
        managedServices.append(RetrievalLeakReportWorker(
            fluent: services.fluent,
            logger: Logger(label: "lv.retrieval.leakreport"),
            surfaceInsight: surfaceInsight
        ))
    }

    // HER-235 3D viz — graph layout worker. Recomputes each tenant's persisted
    // 3D PCA layout when new memories arrive. No external traffic (pure DB +
    // in-process PCA), so on by default outside test. Toggle via
    // `GRAPH_LAYOUT_WORKER_ENABLED=false`.
    if fluentEnabled, lvEnvironment != "test",
       reader.string(forKey: "graphLayout.workerEnabled", default: "true").lowercased() == "true"
    {
        managedServices.append(GraphLayoutWorker(fluent: services.fluent))
    }

    // Cross-model context: final grounded answers are persisted first, then
    // embedded by a durable outbox worker. Fresh-chat answers never enqueue.
    if fluentEnabled, lvEnvironment != "test" {
        managedServices.append(MemoryIndexWorker(
            fluent: services.fluent,
            embeddings: embeddingService
        ))
    }

    // Durable claim/entity/event extraction. The worker is feature-gated for
    // a measured backfill rollout; graph reads remain available while off.
    if fluentEnabled, lvEnvironment != "test",
       reader.string(forKey: "knowledgeGraph.workerEnabled", default: "true").lowercased() == "true"
    {
        let modelExtractionEnabled = reader.string(
            forKey: "knowledgeGraph.modelExtractionEnabled",
            default: "false"
        ).lowercased() == "true"
        managedServices.append(KnowledgeExtractionWorker(
            fluent: services.fluent,
            push: pushService,
            transport: modelExtractionEnabled ? routedTransport : nil,
            model: modelExtractionEnabled ? services.hermesDefaultModel : nil
        ))
        routingLogger.info("knowledge graph model adjudication \(modelExtractionEnabled ? "enabled" : "disabled")")
    } else {
        routingLogger.info("knowledge graph worker disabled (set KNOWLEDGE_GRAPH_WORKER_ENABLED=true to enable)")
    }

    // HER-245 / HER-259 — Sessions list. Joins conversations + messages.
    let sessionsController = SessionsController(
        fluent: services.fluent,
        logger: Logger(label: "lv.sessions")
    )
    let sessionsGroup = router.group("/v1/sessions").add(middleware: jwtAuthenticator)
    sessionsController.addRoutes(to: sessionsGroup)

    // Health ingest (HealthKit / Google Fit / manual) — protected.
    // HER-202 — read of own data is mounted on a separate group so the
    // `EntitlementMiddleware` only gates ingest. A `lapsed`/`archived`
    // tier can still read their own samples (export-window behaviour),
    // matching how `/v1/memory` read routes are wired.
    let healthController = HealthIngestController(
        fluent: services.fluent,
        eventBus: eventBus,
        logger: Logger(label: "lv.health")
    )
    let healthIngestGroup = router.group("/v1/health").add(middleware: jwtAuthenticator)
        .add(middleware: EntitlementMiddleware(requires: .healthIngest, enforcementEnabled: services.billingEnforcementEnabled))
    healthController.addRoutes(to: healthIngestGroup)
    let healthReadGroup = router.group("/v1/health").add(middleware: jwtAuthenticator)
    healthController.addReadRoutes(to: healthReadGroup)

    // Apple Reminders (EventKit) selective-sync ingest — persists the device's
    // reminder deltas into the `apple_reminders` cache that the Hermes
    // `reminders_list` tool reads in the background (device-RPC stays fallback).
    let appleRemindersController = AppleRemindersController(
        fluent: services.fluent,
        logger: Logger(label: "lv.apple.reminders")
    )
    let appleRemindersGroup = router.group("/v1/reminders").add(middleware: jwtAuthenticator)
    appleRemindersController.addRoutes(to: appleRemindersGroup)

    // Admin: hermes-profile reconciliation. Shared-secret gated; off when
    // `admin.token` is empty.
    // HER-226 — gateway-reachability probe shared by reconciler + service
    // log line. Single actor across the app so the 30 s TTL caches one
    // probe per gateway URL regardless of caller.
    let gatewayProbe = HermesGatewayProbe(
        session: .shared,
        logger: Logger(label: "lv.hermes.probe"),
        apiKey: services.hermesAPIKey
    )
    let reconciler = HermesProfileReconciler(
        fluent: services.fluent,
        service: hermesProfileService,
        vaultPaths: vaultPaths,
        hermesDataRoot: services.hermesDataRoot,
        hermesGatewayURL: services.hermesGatewayURL,
        gatewayProbe: gatewayProbe,
        logger: Logger(label: "lv.admin")
    )
    let adminController = AdminController(reconciler: reconciler)
    let adminGroup = router.group("/v1/admin/hermes-profiles")
        .add(middleware: AdminTokenMiddleware<AppRequestContext>(expectedToken: services.adminToken))
    adminController.addRoutes(to: adminGroup)

    // Deep health — round-trips Hermes `GET /v1/models` via the shared
    // gateway probe (HER-226, Bearer `hermes.apiKey`). Deliberately separate
    // from the shallow `/health` (process liveness): a Hermes outage degrades
    // THIS endpoint to 503 without flipping the API pod NotReady, so plain
    // CRUD keeps serving while uptime monitors still see the AI path is down.
    // Unauthenticated + secret-free (reports only reachability + latency).
    router.get("/health/deep") { _, _ -> Response in
        let result = await gatewayProbe.probe(gatewayURL: services.hermesGatewayURL)
        let latency = result.latencyMs.map(String.init) ?? "null"
        let json = #"{"status":"\#(result.reachable ? "ok" : "degraded")","hermes":{"reachable":\#(result.reachable),"latencyMs":\#(latency)}}"#
        var headers = HTTPFields()
        headers[.contentType] = "application/json"
        return Response(
            status: result.reachable ? .ok : .serviceUnavailable,
            headers: headers,
            body: .init(byteBuffer: ByteBuffer(string: json))
        )
    }

    // HER-164 — admin LLM health-check fanout. `GET /admin/llm/health`
    // pings every registered OpenAI-compatible provider concurrently
    // and returns one row per upstream with status + latency, so the
    // ops dashboard can spot a dead key or upstream outage at a glance.
    let llmHealthController = LLMHealthController(
        registry: providerRegistry,
        logger: routingLogger
    )
    let llmHealthGroup = router.group("/admin")
        .add(middleware: AdminTokenMiddleware<AppRequestContext>(expectedToken: services.adminToken))
    llmHealthController.addRoutes(to: llmHealthGroup)

    // HER-29 — daily 04:00 UTC self-heal pass over `hermes_profiles`. Picks
    // up rows left in `error` / `provisioning` by signup soft-fails and
    // retries `HermesProfileService.ensure`. Runs in-process via
    // `ServiceLifecycle`, mirroring `LapseArchiverService`.
    //
    // HER-310 — skip registration entirely under `lv.environment=test`.
    // `app.test(.router)` boots the ServiceGroup and immediately
    // graceful-shuts it down; the reconciler's startup `health()` probe
    // races `Databases.shutdownAsync()` and asserts inside
    // `Databases._requireDefaultID()`, SIGILL-ing the test binary on
    // process exit. The reconciler is operational scaffolding — tests
    // never exercise it, so unhooking it is the cleanest fix.
    if fluentEnabled, lvEnvironment != "test" {
        managedServices.append(HermesProfileReconcilerService(
            reconciler: reconciler,
            logger: Logger(label: "lv.admin")
        ))
    }

    // Admin: HER-146 Apple Health correlation engine. Shared-secret gated.
    // Host cron drives this nightly via `POST /v1/admin/health/correlate`.
    let healthCorrelationService = HealthCorrelationService(
        transport: routedTransport,
        fluent: services.fluent,
        embeddings: embeddingService,
        memories: MemoryRepository(fluent: services.fluent),
        defaultModel: services.hermesDefaultModel,
        logger: Logger(label: "lv.health-correlate")
    )
    let healthCorrelationJob = HealthCorrelationJob(
        fluent: services.fluent,
        service: healthCorrelationService,
        logger: Logger(label: "lv.health-correlate")
    )
    let healthAdminGroup = router.group("/v1/admin/health")
        .add(middleware: AdminTokenMiddleware<AppRequestContext>(expectedToken: services.adminToken))
    HealthAdminController(job: healthCorrelationJob).addRoutes(to: healthAdminGroup)

    // Admin: HER-147 memory scoring + pruning. Shared-secret gated.
    // Monthly host cron: `POST /v1/admin/memory/prune`.
    let memoryScoringService = MemoryScoringService(
        fluent: services.fluent,
        logger: Logger(label: "lv.memory-scoring")
    )
    let memoryPruningService = MemoryPruningService(
        fluent: services.fluent,
        logger: Logger(label: "lv.memory-pruning")
    )
    let memoryPruningJob = MemoryPruningJob(
        fluent: services.fluent,
        scoring: memoryScoringService,
        pruning: memoryPruningService,
        logger: Logger(label: "lv.memory-pruning")
    )
    let memoryAdminGroup = router.group("/v1/admin/memory")
        .add(middleware: AdminTokenMiddleware<AppRequestContext>(expectedToken: services.adminToken))
    MemoryAdminController(
        scoring: memoryScoringService,
        pruning: memoryPruningService,
        job: memoryPruningJob
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
    // Apple Integration P0b — device-RPC result callback.
    DeviceCommandController(
        broker: .shared,
        logger: Logger(label: "lv.apple.device-rpc")
    ).addRoutes(to: deviceGroup)

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

    // P3 — /v1/me/hermes/capabilities: feature-detect the connected Hermes
    // so clients gate each settings pane (live / read-only / unsupported).
    if let hermesCapabilitiesService {
        let capabilitiesGroup = router.group("/v1/me/hermes/capabilities")
            .add(middleware: jwtAuthenticator)
            .add(middleware: RateLimitMiddleware(policy: .settingsByUser, storage: rateLimitStorage))
        HermesCapabilitiesController(service: hermesCapabilitiesService).addRoutes(to: capabilitiesGroup)
    }

    // HER-252 — /v1/me/providers (CRUD + test) and /v1/me/preferences/llm
    // (GET/PUT) for per-user LLM credential + routing preferences.
    // Providers controller only mounts when SecretBox is available (it
    // needs the per-tenant key to seal API keys at rest). Preferences
    // controller has no crypto dependency so it mounts unconditionally.
    if let userCredentialStore {
        let providersController = ProvidersController(
            credentialStore: userCredentialStore,
            fluent: services.fluent,
            logger: Logger(label: "lv.me.providers")
        )
        let providersGroup = router.group("/v1/me/providers")
            .add(middleware: jwtAuthenticator)
            .add(middleware: RateLimitMiddleware(policy: .settingsByUser, storage: rateLimitStorage))
        providersController.addRoutes(to: providersGroup)
    }

    // HER-241 — /v1/me/hermes-gateways (list / get / put / delete / test).
    // Mounted alongside providers under the same JWT + rate-limit policy.
    // `byoHermesMiddleware` is added when available so `/test` can read
    // the user's resolved Hermes base URL + auth header from
    // `ctx.hermesResolution`; without it /test returns
    // `hermes_not_configured`.
    if let hermesGatewaysController {
        let hermesGatewaysBase = router.group("/v1/me/hermes-gateways")
            .add(middleware: jwtAuthenticator)
            .add(middleware: RateLimitMiddleware(policy: .settingsByUser, storage: rateLimitStorage))
        let hermesGatewaysGroup = byoHermesMiddleware
            .map { hermesGatewaysBase.add(middleware: $0) } ?? hermesGatewaysBase
        hermesGatewaysController.addRoutes(to: hermesGatewaysGroup)

        // Sidecar-called inbound webhook for Photon events. This route cannot
        // use user JWTs, so it is gated by the same shared token used for the
        // Photon sidecar control plane.
        let photonWebhook = router.group("/v1/gateways/photon")
            .add(middleware: SidecarTokenMiddleware<AppRequestContext>(expectedToken: services.photonSidecarToken))
        photonWebhook.post("inbound", use: hermesGatewaysController.handlePhotonInbound)
    }
    let llmPrefsController = LLMPreferencesController(
        repository: userLLMPreferenceRepo,
        routerProfiles: routerProfileRepo,
        defaultPrimaryModel: services.hermesDefaultManagedModel,
        logger: Logger(label: "lv.me.llm-prefs")
    )
    let llmPrefsGroup = router.group("/v1/me/preferences/llm")
        .add(middleware: jwtAuthenticator)
        .add(middleware: RateLimitMiddleware(policy: .settingsByUser, storage: rateLimitStorage))
    llmPrefsController.addRoutes(to: llmPrefsGroup)

    // Cerberus Router profile/rule management, scoped assignments, model
    // catalog, and prompt-free cost/performance analytics.
    let cerberusGroup = router.group("/v1/router")
        .add(middleware: jwtAuthenticator)
        .add(middleware: RateLimitMiddleware(policy: .settingsByUser, storage: rateLimitStorage))
    RouterController(
        repository: routerProfileRepo,
        fluent: services.fluent,
        ensemblesEnabled: cerberusParallelEnabled,
        credentials: userCredentialStore
    ).addRoutes(to: cerberusGroup)
    ParallelController(
        transport: routedTransport,
        store: parallelStore,
        fluent: services.fluent,
        memories: MemoryRepository(fluent: services.fluent),
        embeddings: embeddingService,
        enabled: cerberusParallelEnabled
    ).addRoutes(to: cerberusGroup)

    // Usability layer — one task-based settings surface for connection
    // statuses, test-all diagnostics, and recent diagnostic events.
    let connectionsController = ConnectionsController(
        fluent: services.fluent,
        logger: Logger(label: "lv.me.connections")
    )
    let connectionsGroup = router.group("/v1/me/connections")
        .add(middleware: jwtAuthenticator)
        .add(middleware: RateLimitMiddleware(policy: .settingsByUser, storage: rateLimitStorage))
    connectionsController.addRoutes(to: connectionsGroup)

    // HER-240a — /v1/integrations/xai routes. Mounted only when the master
    // secret is set (same gate as BYO Hermes); a missing secret means the
    // tenant container manager can't seal the API_SERVER_KEY, so the routes
    // 404 in that mode rather than misbehave.
    if let xaiOAuthController {
        let integrationsGroup = router.group("/v1")
            .add(middleware: jwtAuthenticator)
        xaiOAuthController.addRoutes(to: integrationsGroup)
    }

    // Nous Subscription Integration — /v1/integrations/nous routes. Same
    // secret gate as xai: without the master secret the tenant container
    // manager can't run, so these routes 404 in that mode.
    if let nousOAuthController {
        let nousIntegrationsGroup = router.group("/v1")
            .add(middleware: jwtAuthenticator)
        nousOAuthController.addRoutes(to: nousIntegrationsGroup)
    }

    // HER-240c — /v1/grok/* routes. JWT-protected + premium-gated. 402 for
    // free/trial users, 409 for premium users without an active xai-oauth.
    if let grokController {
        let grokGroup = router.group("/v1")
            .add(middleware: jwtAuthenticator)
            .add(middleware: PremiumGuardMiddleware(logger: Logger(label: "lv.grok.premium-guard")))
        grokController.addRoutes(to: grokGroup)
    }

    // HER-330 — /v1/system/hermes/* self-update routes. Gated by BOTH the JWT
    // authenticator (authenticated owner) AND the shared admin token, since an
    // update affects every tenant on the box. Mounted only when the master
    // secret is set (same gate as the container manager it drives).
    if let hermesUpdateController {
        let systemHermesGroup = router.group("/v1/system/hermes")
            .add(middleware: jwtAuthenticator)
            .add(middleware: AdminTokenMiddleware<AppRequestContext>(expectedToken: services.adminToken))
        hermesUpdateController.addRoutes(to: systemHermesGroup)
    }

    // Account management (HER-92) — DELETE /v1/account (GDPR data wipe).
    let accountDeletionService = AccountDeletionService(
        fluent: services.fluent,
        hasher: BcryptPasswordHasher(),
        vaultPaths: vaultPaths,
        hermesDataRoot: services.hermesDataRoot,
        logger: Logger(label: "lv.account")
    )
    let accountController = AccountController(
        service: accountDeletionService,
        jwtKeys: services.jwtKeys
    )
    let accountGroup = router.group("/v1/account").add(middleware: jwtAuthenticator)
    accountController.addRoutes(to: accountGroup)

    // Skills runtime (HER-148) — generic skill runner, per-tenant catalog,
    // cron scheduler, in-process event bus, optional context router.
    // Manual runs are live through /v1/skills/:name/run and chat slash
    // commands dispatch through /v1/skills/slash.
    // HER-193 — per-skill daily run cap guard. Reads cap values from
    // each manifest's `metadata.daily_run_cap`; SkillRunner calls
    // checkAndIncrement before LLM dispatch and recordFailure on error
    // so failed runs don't burn quota.
    let skillRunCapGuard = SkillRunCapGuard(
        fluent: services.fluent,
        logger: skillsLogger
    )
    let skillRunner = SkillRunner(
        catalog: skillCatalog,
        transport: routedTransport,
        memories: MemoryRepository(fluent: services.fluent),
        embeddings: embeddingService,
        apns: pushService,
        defaultModel: services.hermesDefaultModel,
        fluent: services.fluent,
        vaultPaths: vaultPaths,
        capGuard: skillRunCapGuard,
        eventBus: eventBus,
        usageMeter: usageMeterService,
        logger: skillsLogger
    )
    // HER-171 — fire-and-forget; the actor stores the subscription Tasks
    // internally so they stay alive for the lifetime of the application.
    Task { await skillRunner.startEventSubscriptions() }
    let cronScheduler = CronScheduler(
        catalog: skillCatalog,
        runner: skillRunner,
        fluent: services.fluent,
        push: pushService,
        logger: skillsLogger
    )
    // HER-200 M4 — surface CronScheduler to ServiceGroup so `run()` is
    // invoked for the application's lifetime. No-op today (catalog empty);
    // becomes load-bearing once HER-169 lands skill dispatch.
    if fluentEnabled, lvEnvironment != "test" {
        managedServices.append(cronScheduler)
    }
    // HER-Reminders — per-minute reminder firing. Same single-replica gate
    // as CronScheduler; shares the APNS push service.
    let reminderScheduler = ReminderScheduler(
        fluent: services.fluent,
        push: pushService,
        logger: Logger(label: "lv.reminders.scheduler")
    )
    if fluentEnabled, lvEnvironment != "test" {
        managedServices.append(reminderScheduler)
    }
    let skillsGroup = router.group("/v1/skills")
        .add(middleware: jwtAuthenticator)
        .add(middleware: RateLimitMiddleware(policy: .skillRunByUser, storage: rateLimitStorage))
    SkillsController(
        runner: skillRunner,
        catalog: skillCatalog,
        memoryCompileController: memoryCompileController,
        fluent: services.fluent,
        enforcementEnabled: services.billingEnforcementEnabled,
        logger: skillsLogger
    ).addRoutes(to: skillsGroup)

    // HER-177 — Today-tab skill outputs feed.
    SkillOutputsController(logger: skillsLogger).addRoutes(to: skillsGroup)

    // Lumina Jobs P3 — chat→job detection + creation (POST /v1/jobs[/detect]).
    let jobsGroup = router.group("/v1/jobs").add(middleware: jwtAuthenticator)
    let jobAuthoring = JobAuthoring(
        vaultPaths: vaultPaths,
        fluent: services.fluent,
        logger: Logger(label: "lv.jobs")
    )
    JobsController(
        classifier: JobIntentClassifier(transport: routedTransport, model: services.hermesDefaultModel),
        authoring: jobAuthoring,
        logger: Logger(label: "lv.jobs")
    ).addRoutes(to: jobsGroup)

    // Automation 2.0 — durable, versioned visual workflows. Execution is
    // claimed from Postgres so the API can scale beyond one replica safely.
    let workflowStudioEnabled = reader.bool(forKey: ConfigKey("cerberus.studio.enabled"), default: true)
    if workflowStudioEnabled {
        let workflowEvents = WorkflowEventStore(
            fluent: services.fluent,
            logger: Logger(label: "lv.workflows.events")
        )
        let workflowSpend = WorkflowSpendService(
            fluent: services.fluent,
            logger: Logger(label: "lv.workflows.spend"),
            globalDailyUsdMicros: Int64(reader.int(forKey: "cerberus.studio.globalDailyUsdMicros", default: 10_000_000)),
            globalMonthlyUsdMicros: Int64(reader.int(forKey: "cerberus.studio.globalMonthlyUsdMicros", default: 100_000_000)),
            managedInferenceAvailable: platformOpenRouterKey.isEmpty == false
        )
        let workflowService = WorkflowService(fluent: services.fluent, spend: workflowSpend, events: workflowEvents)
        let workflowWebhookController = WorkflowWebhookController(
            fluent: services.fluent,
            secretBox: secretBoxRef,
            workflowService: workflowService
        )
        workflowWebhookController.addPublicRoutes(to: router)
        let workflowsGroup = router.group("/v1/workflows").add(middleware: jwtAuthenticator)
        WorkflowController(
            service: workflowService,
            webhookController: workflowWebhookController,
            eventStore: workflowEvents,
            selfImprovement: selfImprovementService
        ).addRoutes(to: workflowsGroup)
        let templatesGroup = router.group("/v1/workflow-templates").add(middleware: jwtAuthenticator)
        WorkflowTemplateController(service: workflowService).addRoutes(to: templatesGroup)
        if fluentEnabled, lvEnvironment != "test" {
            managedServices.append(WorkflowEngine(
                fluent: services.fluent,
                transport: routedTransport,
                defaultModel: services.hermesDefaultModel,
                skillRunner: skillRunner,
                skillCatalog: skillCatalog,
                embeddings: embeddingService,
                profiles: routerProfileRepo,
                spend: workflowSpend,
                events: workflowEvents,
                push: pushService,
                logger: Logger(label: "lv.workflows.worker"),
                workerCount: reader.int(forKey: "cerberus.studio.workerCount", default: 4)
            ))
            managedServices.append(WorkflowScheduler(
                fluent: services.fluent,
                workflowService: workflowService,
                logger: Logger(label: "lv.workflows.scheduler")
            ))
            managedServices.append(WorkflowMaintenanceService(
                fluent: services.fluent,
                events: workflowEvents,
                logger: Logger(label: "lv.workflows.maintenance")
            ))
            managedServices.append(LegacyJobWorkflowMigrator(
                fluent: services.fluent,
                catalog: skillCatalog,
                logger: Logger(label: "lv.workflows.legacy-migrator")
            ))
        }
    }

    // Apple Ecosystem Integration P0 — per-domain data-access consent.
    let appleGroup = router.group("/v1/apple").add(middleware: jwtAuthenticator)
    AppleConsentController(
        fluent: services.fluent,
        logger: Logger(label: "lv.apple.consent")
    ).addRoutes(to: appleGroup)

    // Apple Photos derived-text index (M81) — consent-gated OCR + scene-tag
    // ingest into pgvector for semantic recall. /v1/photos/index.
    let photosGroup = router.group("/v1/photos").add(middleware: jwtAuthenticator)
    PhotoIndexController(
        fluent: services.fluent,
        embeddings: embeddingService,
        logger: Logger(label: "lv.apple.photos")
    ).addRoutes(to: photosGroup)

    // Apple Calendar (EventKit) selective-sync — persists derived event
    // metadata into `calendar_events` (source = "apple_eventkit") so the
    // `calendar_query` Hermes tool reads a server cache in the background.
    // Consent-gated on `.calendar` inside the controller. Mirrors the
    // `/v1/health` ingest wiring (JWT + per-user rate-limit only).
    let appleCalendarSyncGroup = router.group("/v1/calendar").add(middleware: jwtAuthenticator)
    AppleCalendarController(
        fluent: services.fluent,
        logger: Logger(label: "lv.apple.calendar")
    ).addRoutes(to: appleCalendarSyncGroup)

    // HER-179 — per-tenant APNS category opt-out under /v1/me/apns-categories.
    let apnsPrefsGroup = router.group("/v1/me").add(middleware: jwtAuthenticator)
    ApnsCategoryPrefsController(
        fluent: services.fluent,
        logger: Logger(label: "lv.me.apns-prefs")
    ).addRoutes(to: apnsPrefsGroup)

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

    // Native Kanban — LuminaVault-owned boards. JWT + per-user rate limit.
    let kanbanController = KanbanController(
        service: KanbanService(fluent: services.fluent, authoring: jobAuthoring),
        vaultAccess: vaultAccessService,
        activity: vaultActivityRecorder
    )
    let boardsGroup = router.group("/v1/boards")
        .add(middleware: jwtAuthenticator)
        .add(middleware: RateLimitMiddleware(policy: .settingsByUser, storage: rateLimitStorage))
    kanbanController.addRoutes(to: boardsGroup)
    let cardsGroup = router.group("/v1/cards")
        .add(middleware: jwtAuthenticator)
        .add(middleware: RateLimitMiddleware(policy: .settingsByUser, storage: rateLimitStorage))
    kanbanController.addCardRoutes(to: cardsGroup)

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
    /// HER-236: optional swift-log → OTel → otel-collector → PostHog pipeline.
    /// Nil when `OTEL_EXPORTER_OTLP_LOGS_ENDPOINT` is unset (log shipping off).
    let logs: (any Service)?
}

/// Same single-shot pattern as `bootstrapMetricsOnce` — guards against
/// multiple `buildApplication` calls in a single test process.
private actor OTelLatch {
    static let shared = OTelLatch()
    private var services: OTelServices?

    func bootstrap(serviceName: String, logLevel: Logger.Level) async throws -> OTelServices {
        if let services {
            return services
        }

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

        // HER-236: OTLP log pipeline → otel-collector (JSON/HTTP) → PostHog.
        // Opt-in via OTEL_EXPORTER_OTLP_LOGS_ENDPOINT; absent = no log shipping
        // and the stock console handler stays installed.
        var logsService: (any Service)?
        if let logsEndpoint = environment["OTEL_EXPORTER_OTLP_LOGS_ENDPOINT"],
           !logsEndpoint.isEmpty
        {
            let logExporter = OTLPHTTPLogExporter(endpoint: logsEndpoint)
            let logProcessor = OTelBatchLogRecordProcessor(
                exporter: logExporter,
                configuration: .init(environment: environment)
            )
            LoggingSystem.bootstrap { _ in
                OTelLogHandler(processor: logProcessor, logLevel: logLevel, resource: resource)
            }
            logsService = logProcessor
        }

        let bundle = OTelServices(metrics: metricsReader, tracer: tracer, logs: logsService)
        services = bundle
        return bundle
    }
}

private func bootstrapOTelOnce(serviceName: String, logLevel: Logger.Level) async throws -> OTelServices {
    try await OTelLatch.shared.bootstrap(serviceName: serviceName, logLevel: logLevel)
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

func makeHermesGateway(
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
    return try MeResponse(
        userId: user.requireID(),
        email: user.email,
        username: user.username,
        isVerified: user.isVerified,
        privacyNoCNOrigin: user.privacyNoCNOrigin,
        contextRouting: user.contextRouting,
        autoSaveLinks: user.autoSaveLinks,
        mnemosyneEnabled: user.mnemosyneEnabled,
        isAdmin: user.isAdmin
    )
}

/// HER-176 / HER-172: `PUT /v1/me/privacy`. Flips
/// `users.privacy_no_cn_origin` and/or `users.context_routing`. Both
/// fields optional; only the ones present in the body are mutated.
/// Takes effect on the next inbound request — ModelRouter + ContextRouter
/// read from `User` on each request, no caching to invalidate.
private func updatePrivacyHandler(
    fluent: Fluent
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
        if let autoSave = body.autoSaveLinks {
            user.autoSaveLinks = autoSave
        }
        if let mnemosyne = body.mnemosyneEnabled {
            user.mnemosyneEnabled = mnemosyne
        }
        try await user.save(on: fluent.db())
        return try MeResponse(
            userId: user.requireID(),
            email: user.email,
            username: user.username,
            isVerified: user.isVerified,
            privacyNoCNOrigin: user.privacyNoCNOrigin,
            contextRouting: user.contextRouting,
            autoSaveLinks: user.autoSaveLinks,
            mnemosyneEnabled: user.mnemosyneEnabled,
            isAdmin: user.isAdmin
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
    enforcementEnabled: Bool
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
            enforcementEnabled: enforcementEnabled
        )
    }
}

private func meUsageHandler(
    fluent: Fluent
) -> @Sendable (Request, AppRequestContext) async throws -> MeUsageResponse {
    { _, ctx in
        let user = try ctx.requireIdentity()
        let service = UsageMetricsService(fluent: fluent)
        return try await service.currentMonthUsage(for: user)
    }
}
