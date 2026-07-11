import Crypto
import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import LuminaVaultShared

extension WorkflowWebhookCredentialDTO: @retroactive ResponseEncodable {}

struct WorkflowWebhookController {
    static let maxBodyBytes = 1024 * 1024
    static let replayWindow: TimeInterval = 5 * 60

    let fluent: Fluent
    let secretBox: SecretBox?

    func addPublicRoutes(to router: Router<AppRequestContext>) {
        router.post("/v1/workflow-hooks/:hookID", use: ingest)
    }

    func rotate(tenantID: UUID, workflowID: UUID) async throws -> WorkflowWebhookCredentialDTO {
        guard let secretBox else { throw HTTPError(.serviceUnavailable, message: "workflow_webhooks_require_secret_master_key") }
        guard let workflow = try await Workflow.query(on: fluent.db(), tenantID: tenantID)
            .filter(\.$id == workflowID).first()
        else { throw WorkflowServiceError.notFound }
        guard workflow.draftDefinition.trigger == .webhook else {
            throw WorkflowServiceError.invalid("workflow trigger must be webhook")
        }
        let secret = randomSecret()
        let sealed = try secretBox.seal(secret, tenantID: tenantID)
        let row = try await WorkflowWebhook.query(on: fluent.db(), tenantID: tenantID)
            .filter(\.$workflowID == workflowID).first() ?? WorkflowWebhook()
        if row.id == nil {
            row.id = UUID(); row.tenantID = tenantID; row.workflowID = workflowID
        }
        row.secretCiphertext = sealed.ciphertext; row.secretNonce = sealed.nonce
        try await row.save(on: fluent.db())
        let hookID = try row.requireID()
        return WorkflowWebhookCredentialDTO(hookID: hookID, path: "/v1/workflow-hooks/\(hookID)", secret: secret)
    }

    @Sendable func ingest(_ request: Request, ctx: AppRequestContext) async throws -> WorkflowRunDTO {
        guard let secretBox else { throw HTTPError(.serviceUnavailable, message: "workflow_webhooks_unavailable") }
        guard let rawID = ctx.parameters.get("hookID"), let hookID = UUID(uuidString: rawID),
              let hook = try await WorkflowWebhook.find(hookID, on: fluent.db())
        else { throw HTTPError(.notFound, message: "workflow_hook_not_found") }
        guard let timestampRaw = request.headers[.init("x-lumina-timestamp")!],
              let timestamp = TimeInterval(timestampRaw),
              abs(Date().timeIntervalSince1970 - timestamp) <= Self.replayWindow,
              let signature = request.headers[.init("x-lumina-signature")!],
              let idempotencyKey = request.headers[.init("idempotency-key")!],
              idempotencyKey.isEmpty == false, idempotencyKey.count <= 200
        else { throw HTTPError(.unauthorized, message: "invalid_workflow_webhook_headers") }
        let buffer = try await request.body.collect(upTo: Self.maxBodyBytes)
        let body = Data(buffer.readableBytesView)
        let secret = try secretBox.open(
            .init(ciphertext: hook.secretCiphertext, nonce: hook.secretNonce),
            tenantID: hook.tenantID
        )
        guard WorkflowWebhookSignature.verify(signature, secret: secret, timestamp: timestampRaw, body: body) else {
            throw HTTPError(.unauthorized, message: "invalid_workflow_webhook_signature")
        }
        let input = payload(body)
        let service = WorkflowService(fluent: fluent)
        return try await service.enqueue(
            tenantID: hook.tenantID,
            workflowID: hook.workflowID,
            trigger: .webhook,
            request: .init(input: input),
            dedupeKey: "webhook:\(idempotencyKey)"
        )
    }

    private func payload(_ body: Data) -> [String: String] {
        var result = ["raw": String(decoding: body, as: UTF8.self)]
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return result }
        for (key, value) in object {
            switch value {
            case let string as String: result[key] = string
            case let number as NSNumber: result[key] = number.stringValue
            case is NSNull: result[key] = ""
            default:
                if let data = try? JSONSerialization.data(withJSONObject: value) {
                    result[key] = String(decoding: data, as: UTF8.self)
                }
            }
        }
        return result
    }

    private func randomSecret() -> String {
        var generator = SystemRandomNumberGenerator()
        return Data((0 ..< 32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }).base64EncodedString()
    }
}

enum WorkflowWebhookSignature {
    static func sign(secret: String, timestamp: String, body: Data) -> String {
        let signed = Data("\(timestamp).".utf8) + body
        return HMAC<SHA256>.authenticationCode(for: signed, using: SymmetricKey(data: Data(secret.utf8)))
            .map { String(format: "%02x", $0) }.joined()
    }

    static func verify(_ signature: String, secret: String, timestamp: String, body: Data) -> Bool {
        constantTimeEquals(sign(secret: secret, timestamp: timestamp, body: body), signature.lowercased())
    }

    private static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8), b = Array(rhs.utf8)
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
