import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
import Logging
import LuminaVaultShared

/// Receives inbound events forwarded by the central Photon sidecar (or directly from Photon fusor webhooks)
/// and delivers them into the tenant's Hermes container so the full agent (skills, vault, KB, memory) runs.
/// Captures the reply and sends it back via the sidecar on the original space.
actor PhotonDeliveryService {
    private let photonClient: any PhotonSidecarClienting
    /// Closure that returns a live handle (port + api key) for a tenant's Hermes container.
    /// In practice provided from HermesContainerManager.ensureRunning.
    private let getHandle: @Sendable (UUID) async throws -> (port: Int, apiKey: String)
    private let logger: Logger
    private let session: URLSession

    init(
        photonClient: any PhotonSidecarClienting,
        getHandle: @escaping @Sendable (UUID) async throws -> (port: Int, apiKey: String),
        logger: Logger,
        session: URLSession = .shared
    ) {
        self.photonClient = photonClient
        self.getHandle = getHandle
        self.logger = logger
        self.session = session
    }

    /// Main entry from the webhook.
    func deliver(_ event: PhotonInboundEvent) async {
        do {
            let handle = try await getHandle(event.tenantId)

            // Build a simple chat completion request against the tenant's api_server.
            // This triggers the full Hermes agent loop (config, skills, Mnemosyne, vault context, etc.)
            // because the /v1/chat/completions on the tenant container is backed by the full gateway.
            let url = URL(string: "http://host.docker.internal:\(handle.port)/v1/chat/completions")!
            var req = URLRequest(url: url, timeoutInterval: 120)
            req.httpMethod = "POST"
            req.setValue("Bearer \(handle.apiKey)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")

            // Use the incoming text as the user message. In a more advanced version we could
            // include space context or a system note "incoming from iMessage via Photon".
            let messages: [[String: Any]] = [
                ["role": "user", "content": event.text],
            ]

            let body: [String: Any] = [
                "model": "hermes-3", // or let the tenant decide via its default
                "messages": messages,
                "stream": false,
                "max_tokens": 2048,
            ]
            req.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
                logger.warning("photon delivery: tenant hermes chat failed", metadata: [
                    "tenant": .stringConvertible(event.tenantId),
                    "status": .stringConvertible((resp as? HTTPURLResponse)?.statusCode ?? 0),
                ])
                return
            }

            // Parse the OpenAI-style response for the assistant text.
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let first = choices.first,
                  let message = first["message"] as? [String: Any],
                  let replyText = message["content"] as? String,
                  !replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                logger.debug("photon delivery: no usable reply text from tenant hermes")
                return
            }

            // Send the reply back on the original space via the sidecar.
            try await photonClient.send(
                projectId: event.projectId,
                spaceId: event.spaceId,
                text: replyText,
                attachments: nil
            )

            logger.info("photon delivery: reply sent", metadata: [
                "tenant": .stringConvertible(event.tenantId),
                "spaceId": .stringConvertible(event.spaceId),
                "len": .stringConvertible(replyText.count),
            ])

        } catch {
            logger.error("photon delivery failed", metadata: [
                "tenant": .stringConvertible(event.tenantId),
                "error": .stringConvertible(String(describing: error)),
            ])
        }
    }
}

/// Wire-format for events forwarded by the sidecar (or Photon).
/// Matches what the sidecar currently emits (see docker/photon-sidecar/index.mjs).
public struct PhotonInboundEvent: Codable, Sendable {
    public let projectId: String
    public let tenantId: UUID
    public let spaceId: String
    public let spaceName: String?
    public let messageId: String?
    public let sender: [String: String]?
    public let text: String
    public let content: [String: String]? // full content if needed later
    public let timestamp: Int?
}
