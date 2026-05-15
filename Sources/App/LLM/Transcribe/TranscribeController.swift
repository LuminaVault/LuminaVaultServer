import Foundation
import HTTPTypes
import Hummingbird
import Logging
import LuminaVaultShared

/// HER-203 — `POST /v1/transcribe` (STT). Accepts a raw audio body with
/// `Content-Type: audio/{m4a,wav,mpeg,webm}`, returns the transcript +
/// per-segment timings. v1.0 routes through a single configured Whisper
/// provider (`transcribe.provider`, default `groq`). Auth + entitlement
/// + rate-limit are applied by the route group in `App+build.swift`.
struct TranscribeController {
    let service: TranscribeService
    let logger: Logger
    /// Hard cap on the audio body. Anything larger than this short-circuits
    /// with `413 Payload Too Large` before we touch the upstream provider.
    static let maxBodyBytes: Int = 10 * 1024 * 1024

    static let acceptedMimes: Set<String> = [
        "audio/m4a",
        "audio/wav",
        "audio/mpeg",
        "audio/webm",
    ]

    func addRoutes(to router: RouterGroup<AppRequestContext>) {
        router.post("/", use: transcribe)
    }

    @Sendable
    func transcribe(_ request: Request, ctx: AppRequestContext) async throws -> TranscribeResponse {
        let user = try ctx.requireIdentity()
        let tenantID = try user.requireID()

        let mime = (request.headers[.contentType] ?? "")
            .split(separator: ";")
            .first
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            ?? ""
        guard Self.acceptedMimes.contains(mime) else {
            throw HTTPError(.unsupportedMediaType, message: "Content-Type must be one of: \(Self.acceptedMimes.sorted().joined(separator: ", "))")
        }

        if let lengthHeader = request.headers[.contentLength],
           let declared = Int(lengthHeader),
           declared > Self.maxBodyBytes {
            throw HTTPError(.contentTooLarge, message: "audio body exceeds \(Self.maxBodyBytes) byte cap")
        }

        let buffer: ByteBuffer
        do {
            buffer = try await request.body.collect(upTo: Self.maxBodyBytes)
        } catch {
            logger.warning("transcribe body collect failed: \(error)")
            throw HTTPError(.contentTooLarge, message: "audio body exceeds \(Self.maxBodyBytes) byte cap")
        }

        return try await service.transcribe(audio: buffer, mime: mime, tenantID: tenantID)
    }
}
