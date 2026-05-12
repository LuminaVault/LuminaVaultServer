import Foundation
import Hummingbird
import Logging
import NIOCore

/// Receives RevenueCat server-to-server webhook notifications at
/// `POST /v1/billing/revenuecat-webhook`.
///
/// **Not behind JWT** — RevenueCat hits this externally. Authenticated via
/// a shared secret in the `Authorization` header (constant-time compare,
/// same pattern as `AdminTokenMiddleware`). When the secret env var is
/// empty the endpoint returns 503 so a misconfigured prod doesn't silently
/// accept unauthenticated payloads.
struct RevenueCatWebhookController: Sendable {
    let billingService: RevenueCatBillingService
    let webhookSecret: String
    let logger: Logger

    func addRoutes(to group: RouterGroup<AppRequestContext>) {
        group.post("revenuecat-webhook", use: receive)
    }

    @Sendable
    private func receive(
        _ request: Request,
        context: AppRequestContext,
    ) async throws -> Response {
        // ── 1. Verify shared secret ─────────────────────────────────
        try verifySecret(request)

        // ── 2. Collect raw body for audit logging ───────────────────
        var bodyBuffer = ByteBuffer()
        for try await var chunk in request.body {
            bodyBuffer.writeBuffer(&chunk)
        }
        let rawPayload = String(buffer: bodyBuffer)

        // ── 3. Decode payload ───────────────────────────────────────
        let payload: RevenueCatWebhookPayload
        do {
            let decoder = JSONDecoder()
            payload = try decoder.decode(
                RevenueCatWebhookPayload.self,
                from: Data(rawPayload.utf8),
            )
        } catch {
            logger.warning("invalid RevenueCat webhook payload", metadata: [
                "error": .string("\(error)"),
            ])
            throw HTTPError(.badRequest, message: "invalid webhook payload")
        }

        // ── 4. Process ──────────────────────────────────────────────
        try await billingService.process(
            event: payload.event,
            rawPayload: rawPayload,
        )

        return Response(status: .ok)
    }
}

// MARK: - Secret verification

private extension RevenueCatWebhookController {
    /// Validates the `Authorization` header against `REVENUECAT_WEBHOOK_SECRET`.
    /// Rejects immediately if the secret is not configured (fail-closed).
    func verifySecret(_ request: Request) throws {
        guard !webhookSecret.isEmpty else {
            throw HTTPError(
                .serviceUnavailable,
                message: "REVENUECAT_WEBHOOK_SECRET is not configured",
            )
        }

        let provided = request.headers[.authorization]?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let provided, !provided.isEmpty else {
            throw HTTPError(.unauthorized, message: "missing Authorization header")
        }

        guard Self.constantTimeEquals(provided, webhookSecret) else {
            throw HTTPError(.unauthorized, message: "invalid webhook secret")
        }
    }

    /// Avoid early-exit timing leak when comparing secrets.
    static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let ab = Array(a.utf8)
        let bb = Array(b.utf8)
        guard ab.count == bb.count else { return false }
        var diff: UInt8 = 0
        for i in 0 ..< ab.count {
            diff |= ab[i] ^ bb[i]
        }
        return diff == 0
    }
}
