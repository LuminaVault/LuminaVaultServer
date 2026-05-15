import Foundation
import HTTPTypes
import Hummingbird
import Logging
import LuminaVaultShared

/// HER-204 — POST /v1/tts. Text → audio/mpeg. Auth + entitlement (.chat)
/// + rate-limit are applied by the route group in `App+build.swift`; the
/// controller only sees authenticated requests inside the configured
/// throttle envelope.
///
/// Response is a full-buffer MP3 body (no streaming for MVP — ticket
/// explicitly defers streaming). The chunked-transfer encoding the
/// ticket calls out happens at the Hummingbird HTTP layer transparently.
struct TTSController {
    let transport: RoutedTTSTransport
    let telemetry: RouteTelemetry
    let logger: Logger

    /// Hard upper bound on input text size. 4 KB UTF-8 matches the ticket
    /// spec and the OpenAI Audio API's per-request character cap.
    static let maxInputBytes = 4096

    /// Default LuminaVault-side voice when the request omits `voice`.
    static let defaultVoice = "lumina"

    func addRoutes(to router: RouterGroup<AppRequestContext>) {
        router.post("", use: synthesize)
    }

    @Sendable
    func synthesize(_ req: Request, ctx: AppRequestContext) async throws -> Response {
        let user = try ctx.requireIdentity()
        let body = try await req.decode(as: TTSRequest.self, context: ctx)

        guard !body.text.isEmpty else {
            throw HTTPError(.badRequest, message: "text required")
        }
        guard body.text.utf8.count <= Self.maxInputBytes else {
            throw HTTPError(.contentTooLarge, message: "text exceeds \(Self.maxInputBytes) bytes")
        }

        let voice = (body.voice ?? Self.defaultVoice)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedVoice = voice.isEmpty ? Self.defaultVoice : voice

        let userID = try user.requireID()
        let result = try await telemetry.observe("tts.synthesize") {
            try await transport.synthesize(text: body.text, voice: resolvedVoice, userID: userID)
        }

        var headers = HTTPFields()
        if let contentTypeName = HTTPField.Name("Content-Type") {
            headers[contentTypeName] = result.contentType
        }
        if let charsName = HTTPField.Name("X-LuminaVault-Characters-Billed") {
            headers[charsName] = String(result.charactersBilled)
        }
        return Response(
            status: .ok,
            headers: headers,
            body: .init(byteBuffer: ByteBuffer(bytes: result.audioData)),
        )
    }
}
