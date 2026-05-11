import APNS
import APNSCore
import Crypto
import FluentKit
import Foundation
import HummingbirdFluent
import Logging
import NIOPosix

// MARK: - Push categories

/// Mirrors iOS-side `UNNotificationCategory` identifiers. Add new cases
/// here when adding a new notification surface so iOS can group / style
/// them consistently.
enum APNSPushCategory: String {
    case chat
    case nudge
    case digest
    case achievement
}

// MARK: - Push sender protocol (testable seam)

/// Decouples the APNS network call from `APNSNotificationService` so tests
/// can verify fan-out + reaper behavior without a real Apple-issued cert.
protocol APNSPushSender: Sendable {
    func send(
        deviceToken: String,
        title: String,
        subtitle: String?,
        body: String,
        category: APNSPushCategory,
        topic: String,
    ) async throws
}

/// Production impl built on top of `APNSClient`. Constructed only when
/// `apns.enabled=true` and a valid `.p8` is mounted; otherwise the
/// service runs in no-op mode (callers always succeed).
struct LiveAPNSPushSender: APNSPushSender {
    let client: APNSClient<JSONDecoder, JSONEncoder>

    func send(
        deviceToken: String,
        title: String,
        subtitle: String?,
        body: String,
        category: APNSPushCategory,
        topic: String,
    ) async throws {
        let content = APNSAlertNotificationContent(
            title: .raw(title),
            subtitle: subtitle.map { .raw($0) },
            body: .raw(body),
            launchImage: nil,
            sound: APNSAlertNotificationSound.default,
        )
        let notification = APNSAlertNotification(
            alert: content,
            expiration: APNSNotificationExpiration.none,
            priority: .immediately,
            topic: topic,
            payload: ["category": category.rawValue],
        )
        let request = APNSRequest(
            message: notification,
            deviceToken: deviceToken,
            pushType: .alert,
            expiration: .none,
            priority: .immediately,
            apnsID: nil,
            topic: topic,
            collapseID: nil,
        )
        _ = try await client.send(request)
    }
}

// MARK: - Service

/// Per-user push delivery. Looks up every registered `DeviceToken` for
/// the supplied tenant and fans out an alert. Per-token failures are
/// logged and don't abort the batch. APNS errors that mean "this token
/// is dead forever" (`BadDeviceToken`, `Unregistered`,
/// `DeviceTokenNotForTopic`, `MissingDeviceToken`) trigger a hard-delete
/// of the row so we stop pushing to ghost devices.
struct APNSNotificationService {
    let enabled: Bool
    let bundleID: String
    let fluent: Fluent
    let logger: Logger
    let pushSender: (any APNSPushSender)?

    /// Reasons that mean "stop using this token forever". From APNs docs:
    /// https://developer.apple.com/documentation/usernotifications/setting_up_a_remote_notification_server/handling_notification_responses_from_apns
    static let deadTokenReasons: Set<String> = [
        "BadDeviceToken",
        "Unregistered",
        "DeviceTokenNotForTopic",
        "MissingDeviceToken",
    ]

    /// Production-ish constructor. When `apns.enabled=false` or the `.p8`
    /// file is missing, `pushSender` stays nil and `notify*` becomes a
    /// no-op so dev / test runs don't try to ship pushes.
    init(
        enabled: Bool,
        bundleID: String,
        teamID: String,
        keyID: String,
        privateKeyPath: String,
        environment: String,
        fluent: Fluent,
        logger: Logger,
    ) {
        self.enabled = enabled
        self.bundleID = bundleID
        self.fluent = fluent
        self.logger = logger

        if enabled, !privateKeyPath.isEmpty {
            do {
                let client = try Self.makeClient(
                    privateKeyPath: privateKeyPath,
                    environment: environment,
                    keyID: keyID,
                    teamID: teamID,
                )
                pushSender = LiveAPNSPushSender(client: client)
            } catch {
                logger.error("APNS client init failed: \(error)")
                pushSender = nil
            }
        } else {
            pushSender = nil
        }
    }

    /// Test seam: inject a stub `APNSPushSender` directly. Bypasses the
    /// `apns.enabled` gate so tests can drive every code path.
    init(
        bundleID: String,
        fluent: Fluent,
        pushSender: any APNSPushSender,
        logger: Logger,
    ) {
        enabled = true
        self.bundleID = bundleID
        self.fluent = fluent
        self.logger = logger
        self.pushSender = pushSender
    }

    // MARK: - Public surface

    func notifyLLMReply(userID: UUID, username: String, response: ChatResponse) async throws {
        let preview = String(response.message.content.prefix(140))
        try await notify(
            userID: userID,
            title: "LuminaVault reply ready",
            subtitle: username,
            body: preview,
            category: .chat,
        )
    }

    func notifyNudge(userID: UUID, username: String, body: String) async throws {
        try await notify(
            userID: userID,
            title: "Hermes noticed something",
            subtitle: username,
            body: body,
            category: .nudge,
        )
    }

    func notifyDigest(userID: UUID, username: String, body: String) async throws {
        try await notify(
            userID: userID,
            title: "Your daily brief",
            subtitle: username,
            body: body,
            category: .digest,
        )
    }

    /// Single-unlock push surface. Call sites fire one of these per newly
    /// unlocked sub-achievement returned by `AchievementsService.record`.
    /// Best-effort: never blocks the originating request (the caller wraps
    /// this in a detached Task per the `notifyLLMReply` precedent).
    func notifyAchievement(userID: UUID, key _: String, label: String) async throws {
        try await notify(
            userID: userID,
            title: "Achievement unlocked",
            subtitle: label,
            body: "You evolved one step closer to your true form.",
            category: .achievement,
        )
    }

    /// Generic per-user push. Looks up every active `DeviceToken` row,
    /// sends to each, reaps tokens that APNS marks as dead.
    func notify(
        userID: UUID,
        title: String,
        subtitle: String?,
        body: String,
        category: APNSPushCategory,
    ) async throws {
        guard enabled, let pushSender, !bundleID.isEmpty else { return }

        let db = fluent.db()
        let tokens = try await DeviceToken.query(on: db, tenantID: userID).all()
        guard !tokens.isEmpty else {
            logger.debug("apns skipped: no device tokens for tenant \(userID)")
            return
        }

        for row in tokens {
            do {
                try await pushSender.send(
                    deviceToken: row.token,
                    title: title,
                    subtitle: subtitle,
                    body: body,
                    category: category,
                    topic: bundleID,
                )
                row.lastSeenAt = Date()
                try await row.save(on: db)
                logger.debug("apns delivered to \(row.token.prefix(8))… category=\(category.rawValue)")
            } catch {
                if Self.shouldReap(error) {
                    try? await row.delete(on: db)
                    logger.info("apns reaped dead token \(row.token.prefix(8))…: \(error)")
                } else {
                    logger.warning("apns delivery failed for \(row.token.prefix(8))…: \(error)")
                    // Don't bail the whole batch — keep trying remaining tokens.
                }
            }
        }
    }

    // MARK: - Internals

    /// True when the error means "this device token is permanently dead"
    /// per Apple's `Reason` enum. Anything else is a transient failure
    /// the row should survive.
    static func shouldReap(_ error: any Error) -> Bool {
        guard let apnsErr = error as? APNSError, let reason = apnsErr.reason else {
            return false
        }
        return deadTokenReasons.contains(reason.reason)
    }

    private static func makeClient(
        privateKeyPath: String,
        environment: String,
        keyID: String,
        teamID: String,
    ) throws -> APNSClient<JSONDecoder, JSONEncoder> {
        let privateKeyPEM = try String(contentsOfFile: privateKeyPath, encoding: .utf8)
        let privateKey = try P256.Signing.PrivateKey(pemRepresentation: privateKeyPEM)
        let apnsEnvironment: APNSEnvironment = environment.lowercased() == "production" ? .production : .development
        let configuration = APNSClientConfiguration(
            authenticationMethod: .jwt(privateKey: privateKey, keyIdentifier: keyID, teamIdentifier: teamID),
            environment: apnsEnvironment,
        )
        return APNSClient(
            configuration: configuration,
            eventLoopGroupProvider: .shared(MultiThreadedEventLoopGroup.singleton),
            responseDecoder: JSONDecoder(),
            requestEncoder: JSONEncoder(),
        )
    }
}
