import Foundation
import HTTPTypes
import Hummingbird
import Logging
import NIOCore

/// `POST /v1/audio/transcriptions` — an OpenAI-shaped facade over the same
/// `TranscribeService` that backs `/v1/transcribe`.
///
/// It exists so a tenant's Hermes container can point its OpenAI STT client
/// at us instead of at a provider directly, which is what puts voice spend
/// inside our entitlement, rate-limit and metering path. Hermes already
/// supports this shape (it talks to other "managed audio gateways" the same
/// way), so the work is on our side of the wire only.
///
/// Deliberately a thin shim rather than an alias of `TranscribeController`:
/// the request shapes genuinely differ (multipart with form fields vs. a raw
/// body), and the error envelope must be OpenAI's. Everything that actually
/// matters — metering, provider failover, usage rows — lives in
/// `TranscribeService` and is called verbatim, so behaviour cannot drift.
///
/// `POST /v1/audio/speech` is intentionally absent: spoken replies are a
/// later milestone, and shipping the route before the TTS adapter can honour
/// `response_format=opus` would hand Telegram MP3 bytes in an `.ogg` file.
struct OpenAIAudioController {
    let service: TranscribeService
    let logger: Logger

    /// OpenAI's own documented ceiling, and the same cap Hermes applies
    /// before it uploads. Telegram tops out below this for voice notes.
    static let maxBodyBytes: Int = 25 * 1024 * 1024

    /// Extension → mime, used to resolve the audio format.
    ///
    /// Extension is checked **before** the part's `Content-Type` because
    /// httpx frequently labels file parts `application/octet-stream` while
    /// still naming them correctly — and because upstream dispatches on the
    /// extension anyway.
    static let mimeForExtension: [String: String] = [
        "ogg": "audio/ogg",
        "oga": "audio/ogg",
        "opus": "audio/opus",
        "m4a": "audio/m4a",
        "mp4": "audio/mp4",
        "mp3": "audio/mpeg",
        "mpeg": "audio/mpeg",
        "mpga": "audio/mpga",
        "wav": "audio/wav",
        "webm": "audio/webm",
        "flac": "audio/flac",
    ]

    func addTranscriptionRoutes(to router: RouterGroup<AppRequestContext>) {
        router.post("", use: transcriptions)
    }

    func addSpeechRoutes(to router: RouterGroup<AppRequestContext>) {
        router.post("", use: speech)
    }

    /// Placeholder for spoken replies.
    ///
    /// The route is mounted rather than absent on purpose. Tenant containers
    /// are configured with `tts.provider: openai` pointed here, because any
    /// unrecognised provider name in Hermes silently falls back to Edge TTS —
    /// free, keyless, and outside every control on this path. Pointing TTS at
    /// a route that refuses cleanly is what makes "spoken replies are off"
    /// true rather than aspirational.
    ///
    /// A 501 in the OpenAI envelope reaches the user as readable prose via
    /// the SDK's `APIStatusError.message`.
    @Sendable
    func speech(_: Request, ctx: AppRequestContext) async throws -> Response {
        _ = try ctx.requireIdentity()
        throw HTTPError(
            .notImplemented,
            message: "Spoken replies are not available yet. Voice messages you send are still transcribed."
        )
    }

    @Sendable
    func transcriptions(_ request: Request, ctx: AppRequestContext) async throws -> Response {
        let user = try ctx.requireIdentity()
        let tenantID = try user.requireID()

        let contentType = request.headers[.contentType] ?? ""
        guard let boundary = MultipartFormParser.boundary(fromContentType: contentType) else {
            throw HTTPError(
                .badRequest,
                message: "Content-Type must be multipart/form-data with a boundary."
            )
        }

        // Declared-length check first so an oversized upload is refused
        // before we buffer it, then the real cap on collection.
        if let lengthHeader = request.headers[.contentLength],
           let declared = Int(lengthHeader),
           declared > Self.maxBodyBytes
        {
            throw HTTPError(.contentTooLarge, message: Self.tooLargeMessage)
        }

        let buffer: ByteBuffer
        do {
            buffer = try await request.body.collect(upTo: Self.maxBodyBytes)
        } catch {
            throw HTTPError(.contentTooLarge, message: Self.tooLargeMessage)
        }

        let parts: [MultipartFormParser.Part]
        do {
            parts = try MultipartFormParser.parse(buffer, boundary: boundary)
        } catch {
            logger.warning("audio/transcriptions multipart parse failed: \(error)")
            throw HTTPError(.badRequest, message: "Malformed multipart/form-data body.")
        }

        guard let filePart = parts.first(where: { $0.name == "file" }) else {
            throw HTTPError(.badRequest, message: "Missing required form field: file.")
        }
        guard filePart.body.readableBytes > 0 else {
            throw HTTPError(.badRequest, message: "Uploaded audio file is empty.")
        }

        let mime = try Self.resolveMIME(filename: filePart.filename, contentType: filePart.contentType)
        let format = OpenAITranscriptionFormat(
            rawValueOrDefault: parts.first(where: { $0.name == "response_format" })
                .flatMap { $0.body.getString(at: 0, length: $0.body.readableBytes) }
        )

        // `model`, `language`, `temperature` and `prompt` are accepted and
        // ignored: the provider and model are an operator decision made in
        // `TranscribeProviderRegistry`, not something a tenant container
        // gets to choose. Rejecting them instead would break clients that
        // always send a model name.
        let result = try await service.transcribe(audio: filePart.body, mime: mime, tenantID: tenantID)

        return try Self.encode(result, as: format)
    }

    // MARK: - Helpers

    static let tooLargeMessage =
        "Audio file is too large. The maximum size is \(maxBodyBytes / (1024 * 1024)) MB."

    /// Resolves the audio format, preferring the filename extension.
    static func resolveMIME(filename: String?, contentType: String?) throws -> String {
        if let filename, let dot = filename.lastIndex(of: ".") {
            let ext = String(filename[filename.index(after: dot)...]).lowercased()
            if let mime = mimeForExtension[ext] {
                return mime
            }
        }

        if let contentType {
            let normalized = contentType
                .split(separator: ";")
                .first
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                ?? ""
            if TranscribeController.acceptedMimes.contains(normalized) {
                return normalized
            }
        }

        throw HTTPError(
            .badRequest,
            message: "Unsupported audio format. Supported formats: "
                + mimeForExtension.keys.sorted().joined(separator: ", ") + "."
        )
    }

    /// Serialises per `response_format`. All variants are required — Hermes
    /// asks for `text` on `whisper-1` and `json` otherwise, and the SDK casts
    /// the response according to what it requested.
    static func encode(_ result: TranscribeResponse, as format: OpenAITranscriptionFormat) throws -> Response {
        if format.isPlainText {
            return Response(
                status: .ok,
                headers: [.contentType: "text/plain; charset=utf-8"],
                body: .init(byteBuffer: ByteBuffer(string: result.text))
            )
        }

        let data: Data = switch format {
        case .verboseJSON:
            try JSONEncoder().encode(OpenAIVerboseTranscriptionJSON(from: result))
        default:
            try JSONEncoder().encode(OpenAITranscriptionJSON(text: result.text))
        }

        return Response(
            status: .ok,
            headers: [.contentType: "application/json; charset=utf-8"],
            body: .init(byteBuffer: ByteBuffer(bytes: data))
        )
    }
}
