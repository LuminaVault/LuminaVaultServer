import Foundation
import HTTPTypes
import Hummingbird
import Logging
import LuminaVaultShared

/// HER-203 — `POST /v1/transcribe` (STT). Accepts a raw audio body whose
/// `Content-Type` is in `acceptedMimes`, returns the transcript +
/// per-segment timings. v1.0 routes through a single configured Whisper
/// provider (`transcribe.provider`, default `groq`). Auth + entitlement
/// + rate-limit are applied by the route group in `App+build.swift`.
struct TranscribeController {
    let service: TranscribeService
    let logger: Logger
    /// Hard cap on the audio body. Anything larger than this short-circuits
    /// with `413 Payload Too Large` before we touch the upstream provider.
    static let maxBodyBytes: Int = 10 * 1024 * 1024

    /// Every entry must have a real extension in
    /// `GroqWhisperAdapter.filename(for:)` — upstream picks its decoder from
    /// the filename, so accepting a mime we cannot name is a 400 waiting to
    /// happen. `audio/ogg` and `audio/opus` are here for Telegram voice
    /// notes, which are Opus-in-Ogg.
    static let acceptedMimes: Set<String> = [
        "audio/m4a",
        "audio/x-m4a",
        "audio/mp4",
        "audio/wav",
        "audio/x-wav",
        "audio/wave",
        "audio/mpeg",
        "audio/mpga",
        "audio/webm",
        "audio/ogg",
        "audio/opus",
        "audio/flac",
        "audio/x-flac",
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
           declared > Self.maxBodyBytes
        {
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
