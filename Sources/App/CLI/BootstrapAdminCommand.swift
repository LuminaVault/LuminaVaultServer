import Configuration
import FluentKit
import FluentPostgresDriver
import Foundation
import HummingbirdFluent
import JWTKit
import Logging

/// HER-30 — one-shot CLI that seeds (or promotes) the initial admin user.
/// Idempotent: re-running with the same `BOOTSTRAP_ADMIN_EMAIL` finds the
/// existing row and ensures it has `is_admin=true` and `is_verified=true`
/// without creating a duplicate.
///
/// Invocation:
///   `BOOTSTRAP_ADMIN_EMAIL=… BOOTSTRAP_ADMIN_PASSWORD=… swift run App bootstrap-admin`
///   `./App bootstrap-admin`
///
/// On a net-new email this reuses `DefaultAuthService.register` so the trial
/// window, Hermes profile (soft-fail), and SOUL.md side-effects stay in
/// sync with normal signup. After registration the row is promoted in a
/// single save: `isAdmin=true`, `isVerified=true`.
///
/// Required env: `BOOTSTRAP_ADMIN_EMAIL`, `BOOTSTRAP_ADMIN_PASSWORD` (≥12 chars).
/// Optional env: `BOOTSTRAP_ADMIN_USERNAME` (default `admin`),
/// `JWT_HMAC_SECRET` (required for AuthService boot; matches server).
///
/// Output is a single JSON line so setup.sh can capture the IDs.
func runBootstrapAdminCommand(reader: ConfigReader) async throws {
    var logger = Logger(label: "lv.cli.bootstrap-admin")
    logger.logLevel = reader.string(forKey: "log.level", as: Logger.Level.self, default: .info)

    let email = reader.string(forKey: "bootstrap.admin.email", default: "")
    let password = reader.string(forKey: "bootstrap.admin.password", default: "")
    let username = reader.string(forKey: "bootstrap.admin.username", default: "admin")
        .trimmingCharacters(in: .whitespaces)
        .lowercased()
    guard !email.isEmpty, !password.isEmpty else {
        throw BootstrapAdminError.missingCredentials
    }
    let normalizedEmail = email.lowercased()

    let fluent = Fluent(logger: logger)
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

    let summary: BootstrapAdminSummary
    do {
        summary = try await provisionAdmin(
            email: normalizedEmail,
            username: username,
            password: password,
            reader: reader,
            fluent: fluent,
            logger: logger,
        )
    } catch {
        try? await fluent.shutdown()
        throw error
    }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(summary)
    if let json = String(data: data, encoding: .utf8) {
        print(json)
    }

    try await fluent.shutdown()
}

struct BootstrapAdminSummary: Codable {
    let email: String
    let userID: String
    let username: String
    let created: Bool
    let isAdmin: Bool
    let isVerified: Bool
}

enum BootstrapAdminError: Error, CustomStringConvertible {
    case missingCredentials
    case jwtSecretMissing
    case userLookupFailed

    var description: String {
        switch self {
        case .missingCredentials:
            "bootstrap-admin requires BOOTSTRAP_ADMIN_EMAIL and BOOTSTRAP_ADMIN_PASSWORD"
        case .jwtSecretMissing:
            "bootstrap-admin requires JWT_HMAC_SECRET to boot AuthService"
        case .userLookupFailed:
            "bootstrap-admin: register completed but user lookup failed"
        }
    }
}

private func provisionAdmin(
    email: String,
    username: String,
    password: String,
    reader: ConfigReader,
    fluent: Fluent,
    logger: Logger,
) async throws -> BootstrapAdminSummary {
    let repo = DatabaseAuthRepository(fluent: fluent)
    if let existing = try await repo.findUser(byEmail: email) {
        let mutated = try await promote(existing, on: fluent.db())
        let userID = try mutated.requireID().uuidString
        logger.info("bootstrap-admin existing user promoted email=\(email) userID=\(userID)")
        return BootstrapAdminSummary(
            email: mutated.email,
            userID: userID,
            username: mutated.username,
            created: false,
            isAdmin: mutated.isAdmin,
            isVerified: mutated.isVerified,
        )
    }

    let authService = try await makeAuthService(reader: reader, fluent: fluent, logger: logger)
    _ = try await authService.register(email: email, username: username, password: password)

    guard let user = try await repo.findUser(byEmail: email) else {
        throw BootstrapAdminError.userLookupFailed
    }
    let promoted = try await promote(user, on: fluent.db())
    let userID = try promoted.requireID().uuidString
    logger.info("bootstrap-admin created admin user email=\(email) userID=\(userID)")
    return BootstrapAdminSummary(
        email: promoted.email,
        userID: userID,
        username: promoted.username,
        created: true,
        isAdmin: promoted.isAdmin,
        isVerified: promoted.isVerified,
    )
}

private func promote(_ user: User, on db: any Database) async throws -> User {
    var changed = false
    if !user.isAdmin {
        user.isAdmin = true
        changed = true
    }
    if !user.isVerified {
        user.isVerified = true
        changed = true
    }
    if changed {
        try await user.save(on: db)
    }
    return user
}

private func makeAuthService(
    reader: ConfigReader,
    fluent: Fluent,
    logger: Logger,
) async throws -> any AuthService {
    let secret = reader.string(forKey: "jwt.hmac.secret", default: "")
    guard !secret.isEmpty else { throw BootstrapAdminError.jwtSecretMissing }
    let kid = JWKIdentifier(string: reader.string(forKey: "jwt.kid", default: "lv-default"))
    let jwtKeys = JWTKeyCollection()
    await jwtKeys.add(hmac: HMACKey(stringLiteral: secret), digestAlgorithm: .sha256, kid: kid)

    let vaultPaths = VaultPathService(
        rootPath: reader.string(forKey: "vault.rootPath", default: "/tmp/luminavault"),
    )
    let hermesDataRoot = reader.string(forKey: "hermes.dataRoot", default: "/app/data/hermes")
    let gateway = makeHermesGateway(
        kind: reader.string(forKey: "hermes.gatewayKind", default: "filesystem"),
        dataRoot: hermesDataRoot,
        logger: logger,
    )
    let hermesProfileService = HermesProfileService(
        fluent: fluent,
        gateway: gateway,
        vaultPaths: vaultPaths,
    )
    let soulService = SOULService(
        vaultPaths: vaultPaths,
        hermesDataRoot: hermesDataRoot,
        logger: logger,
    )
    let mfaService = DefaultMFAService(
        fluent: fluent,
        sender: LoggingEmailOTPSender(logger: logger),
        generator: DefaultOTPCodeGenerator(),
    )
    return DefaultAuthService(
        repo: DatabaseAuthRepository(fluent: fluent),
        hasher: BcryptPasswordHasher(),
        fluent: fluent,
        jwtKeys: jwtKeys,
        jwtKID: kid,
        mfaService: mfaService,
        resetCodeSender: LoggingEmailOTPSender(logger: logger),
        resetCodeGenerator: DefaultOTPCodeGenerator(),
        verificationCodeSender: LoggingEmailOTPSender(logger: logger),
        verificationCodeGenerator: DefaultOTPCodeGenerator(),
        hermesProfileService: hermesProfileService,
        soulService: soulService,
        logger: logger,
    )
}
