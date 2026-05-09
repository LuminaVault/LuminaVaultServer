import APNS
import APNSCore
import Foundation
import Crypto
import NIOPosix
import Logging

struct APNSNotificationService: Sendable {
    let enabled: Bool
    let bundleID: String
    let teamID: String
    let keyID: String
    let privateKeyPath: String
    let environment: String
    let deviceToken: String
    let logger: Logger
    let client: APNSClient<JSONDecoder, JSONEncoder>?

    init(
        enabled: Bool,
        bundleID: String,
        teamID: String,
        keyID: String,
        privateKeyPath: String,
        environment: String,
        deviceToken: String,
        logger: Logger
    ) {
        self.enabled = enabled
        self.bundleID = bundleID
        self.teamID = teamID
        self.keyID = keyID
        self.privateKeyPath = privateKeyPath
        self.environment = environment
        self.deviceToken = deviceToken
        self.logger = logger

        self.client = try? Self.makeClient(
            privateKeyPath: privateKeyPath,
            environment: environment,
            keyID: keyID,
            teamID: teamID
        )
        if self.client == nil {
            logger.error("Failed to initialize APNS client")
        }
    }

    func notifyLLMReply(username: String, response: ChatResponse) async throws {
        guard enabled, let client = client, !bundleID.isEmpty, !deviceToken.isEmpty else {
            return
        }

        let preview = String(response.message.content.prefix(140))

        let content = APNSAlertNotificationContent(
            title: .raw("LuminaVault reply ready"),
            subtitle: .raw(username),
            body: .raw(preview),
            launchImage: nil,
            sound: APNSAlertNotificationSound.default
        )

        // Use EmptyPayload for no custom payload
        let notification = APNSAlertNotification(alert: content, expiration: APNSNotificationExpiration.none, priority: .immediately, topic: bundleID, payload: "")

        let request = APNSRequest(
            message: notification,
            deviceToken: deviceToken,
            pushType: .alert,
            expiration: .none,
            priority: .immediately,
            apnsID: nil,
            topic: bundleID,
            collapseID: nil
        )

        _ = try await client.send(request)
        logger.info("APNS sent to \(deviceToken) for user \(username)")
    }

    private static func makeClient(
        privateKeyPath: String,
        environment: String,
        keyID: String,
        teamID: String
    ) throws -> APNSClient<JSONDecoder, JSONEncoder> {
        let privateKeyPEM = try String(contentsOfFile: privateKeyPath, encoding: .utf8)
        let privateKey = try P256.Signing.PrivateKey(pemRepresentation: privateKeyPEM)
        let apnsEnvironment: APNSEnvironment = environment.lowercased() == "production" ? .production : .development

        let configuration = APNSClientConfiguration(
            authenticationMethod: .jwt(privateKey: privateKey, keyIdentifier: keyID, teamIdentifier: teamID),
            environment: apnsEnvironment
        )

        return APNSClient(
            configuration: configuration,
            eventLoopGroupProvider: .shared(MultiThreadedEventLoopGroup.singleton),
            responseDecoder: JSONDecoder(),
            requestEncoder: JSONEncoder()
        )
    }
}
