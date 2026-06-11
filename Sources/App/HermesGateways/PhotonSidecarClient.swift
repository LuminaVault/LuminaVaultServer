import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
import Logging
import LuminaVaultShared

/// Client for the central Photon sidecar (Node.js process running spectrum-ts).
///
/// The sidecar holds long-lived Spectrum connections (or registers webhooks via fusor)
/// for enabled tenants and forwards inbound iMessage events to the Lumina API's
/// public webhook. Outbound (replies, typing, attachments) are driven via this control
/// surface from the Swift server after injection into a tenant's Hermes container produces
/// a reply.
///
/// Control calls are authenticated with a shared token (LUMINA_SIDECAR_TOKEN).
/// The sidecar URL is configured via env (e.g. http://photon-sidecar:8789).
protocol PhotonSidecarClienting: Sendable {
    /// Activate a tenant's Photon project in the sidecar (start consuming its message stream).
    func activate(
        projectId: String,
        projectSecret: String,
        tenantId: UUID,
        options: [String: String]?
    ) async throws

    /// Deactivate (stop streaming for the project).
    func deactivate(projectId: String) async throws

    /// Send a reply (or attachment) on behalf of a tenant.
    /// spaceId comes from a prior inbound event.
    func send(
        projectId: String,
        spaceId: String,
        text: String?,
        attachments: [PhotonAttachmentInput]?
    ) async throws -> PhotonSendResult

    /// Health of the sidecar process.
    func health() async -> PhotonSidecarHealth
}

struct PhotonSendResult {
    let ok: Bool
    let messageId: String?
}

struct PhotonAttachmentInput {
    let path: String? // local path the sidecar can read, or base64 later
    let name: String?
    let mimeType: String?
    let caption: String?
    let kind: String // "attachment" | "voice"
}

enum PhotonSidecarHealth: Equatable {
    case healthy(activeProjects: Int)
    case unhealthy(reason: String)
}

struct PhotonSidecarClient: PhotonSidecarClienting {
    let baseURL: URL
    let token: String
    let session: URLSession
    let logger: Logger
    let timeout: TimeInterval

    init(
        baseURL: URL,
        token: String,
        session: URLSession = .shared,
        logger: Logger,
        timeout: TimeInterval = 30
    ) {
        self.baseURL = baseURL
        self.token = token
        self.session = session
        self.logger = logger
        self.timeout = timeout
    }

    func activate(projectId: String, projectSecret: String, tenantId: UUID, options: [String: String]?) async throws {
        let url = baseURL.appendingPathComponent("control/activate")
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(token, forHTTPHeaderField: "X-Lumina-Sidecar-Token")

        let body: [String: Any] = [
            "projectId": projectId,
            "projectSecret": projectSecret,
            "tenantId": tenantId.uuidString.lowercased(),
            "options": options ?? [:],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await session.data(for: req)
        try validateResponse(resp, data: data, operation: "activate")
        logger.info("photon sidecar activated project", metadata: [
            "projectId": .stringConvertible(projectId),
            "tenantId": .stringConvertible(tenantId),
        ])
    }

    func deactivate(projectId: String) async throws {
        let url = baseURL.appendingPathComponent("control/deactivate")
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(token, forHTTPHeaderField: "X-Lumina-Sidecar-Token")

        let body = ["projectId": projectId]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await session.data(for: req)
        try validateResponse(resp, data: data, operation: "deactivate")
        logger.info("photon sidecar deactivated project", metadata: [
            "projectId": .stringConvertible(projectId),
        ])
    }

    func send(projectId: String, spaceId: String, text: String?, attachments: [PhotonAttachmentInput]?) async throws -> PhotonSendResult {
        let url = baseURL.appendingPathComponent("control/send")
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(token, forHTTPHeaderField: "X-Lumina-Sidecar-Token")

        var body: [String: Any] = [
            "projectId": projectId,
            "spaceId": spaceId,
        ]
        if let text { body["text"] = text }
        if let atts = attachments, !atts.isEmpty {
            body["attachments"] = atts.map { [
                "path": $0.path as Any,
                "name": $0.name as Any,
                "mimeType": $0.mimeType as Any,
                "caption": $0.caption as Any,
                "kind": $0.kind,
            ] }
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await session.data(for: req)
        try validateResponse(resp, data: data, operation: "send")

        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let ok = json["ok"] as? Bool
        {
            let mid = json["messageId"] as? String
            return PhotonSendResult(ok: ok, messageId: mid)
        }
        return PhotonSendResult(ok: true, messageId: nil)
    }

    func health() async -> PhotonSidecarHealth {
        let url = baseURL.appendingPathComponent("healthz")
        var req = URLRequest(url: url, timeoutInterval: 5)
        req.httpMethod = "GET"

        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
                return .unhealthy(reason: "bad_status")
            }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let active = json["activeProjects"] as? Int
            {
                return .healthy(activeProjects: active)
            }
            return .healthy(activeProjects: -1)
        } catch {
            logger.debug("photon sidecar health failed: \(error)")
            return .unhealthy(reason: "unreachable")
        }
    }

    private func validateResponse(_ response: URLResponse, data: Data, operation: String) throws {
        guard let http = response as? HTTPURLResponse else {
            throw PhotonSidecarError.unexpected("no_http_response")
        }
        if (200 ..< 300).contains(http.statusCode) { return }
        let body = String(data: data, encoding: .utf8) ?? ""
        logger.warning("photon sidecar \(operation) failed", metadata: [
            "status": .stringConvertible(http.statusCode),
            "body": .stringConvertible(body),
        ])
        if http.statusCode == 401 || http.statusCode == 403 {
            throw PhotonSidecarError.unauthorized
        }
        throw PhotonSidecarError.http(status: http.statusCode, body: body)
    }
}

enum PhotonSidecarError: Error, Equatable {
    case unauthorized
    case unexpected(String)
    case http(status: Int, body: String)
}

/// Stub for tests / when sidecar disabled
struct NoopPhotonSidecarClient: PhotonSidecarClienting {
    func activate(projectId _: String, projectSecret _: String, tenantId _: UUID, options _: [String: String]?) async throws {}
    func deactivate(projectId _: String) async throws {}
    func send(projectId _: String, spaceId _: String, text _: String?, attachments _: [PhotonAttachmentInput]?) async throws -> PhotonSendResult {
        PhotonSendResult(ok: true, messageId: "noop-\(UUID().uuidString)")
    }

    func health() async -> PhotonSidecarHealth {
        .healthy(activeProjects: 0)
    }
}
