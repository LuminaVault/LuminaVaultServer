import Foundation
import NIOCore

/// Minimal RFC-7578 `multipart/form-data` reader.
///
/// Hand-rolled deliberately. The server has no multipart dependency and the
/// only producer on this path is the OpenAI Python SDK (httpx), which emits
/// canonical, well-formed bodies; pulling in a general-purpose parser would
/// drag a Vapor-ecosystem tree into a Hummingbird service that has stayed
/// clear of one. The body is size-capped by the caller before it reaches
/// here, so this does no streaming and no incremental buffering.
///
/// It is the read counterpart to `GroqWhisperAdapter.buildMultipartBody`,
/// which writes the same format — the two are tested against each other.
enum MultipartFormParser {
    struct Part: Sendable {
        /// The `name=` parameter of `Content-Disposition`. Required.
        let name: String
        /// The `filename=` parameter, when present. Load-bearing for audio:
        /// upstream Whisper providers dispatch on its extension.
        let filename: String?
        /// The part's own `Content-Type`, when present. Often
        /// `application/octet-stream` from httpx even for typed files, so
        /// callers should prefer `filename` when deciding a format.
        let contentType: String?
        let body: ByteBuffer
    }

    enum ParseError: Error, Equatable {
        /// The request `Content-Type` carried no usable `boundary=`.
        case missingBoundary
        /// No opening delimiter — the body is not multipart at all.
        case noOpeningDelimiter
        /// Truncated: ran out of input before the closing `--boundary--`.
        case unterminated
        /// A part had no header/body separator, or no `name=`.
        case malformedPart
        /// More parts than `maxParts`. A guard against pathological input.
        case tooManyParts
    }

    /// Extracts the `boundary=` parameter from a `Content-Type` header.
    /// Handles quoted and unquoted forms and is case-insensitive on the
    /// parameter name, per RFC 2045.
    static func boundary(fromContentType header: String) -> String? {
        for parameter in header.split(separator: ";").dropFirst() {
            let trimmed = parameter.trimmingCharacters(in: .whitespaces)
            guard let equals = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[trimmed.startIndex ..< equals].trimmingCharacters(in: .whitespaces)
            guard key.lowercased() == "boundary" else { continue }

            var value = String(trimmed[trimmed.index(after: equals)...])
                .trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// Parses `buffer` into its parts.
    ///
    /// - Parameter maxParts: refuse bodies with more parts than this. The
    ///   OpenAI audio endpoints send at most a handful.
    static func parse(
        _ buffer: ByteBuffer,
        boundary: String,
        maxParts: Int = 32
    ) throws -> [Part] {
        let bytes = Array(buffer.readableBytesView)
        let crlf: [UInt8] = [0x0D, 0x0A]
        let dashes: [UInt8] = [0x2D, 0x2D]
        let delimiter = dashes + Array(boundary.utf8)

        // Skip any preamble before the first delimiter.
        guard var cursor = index(of: delimiter, in: bytes, from: 0) else {
            throw ParseError.noOpeningDelimiter
        }

        var parts: [Part] = []
        while true {
            cursor += delimiter.count

            // `--boundary--` ends the body. Anything after it is epilogue.
            if cursor + 1 < bytes.count, bytes[cursor] == 0x2D, bytes[cursor + 1] == 0x2D {
                return parts
            }
            // Otherwise a CRLF closes the delimiter line. Tolerate the
            // transport-legal linear whitespace some clients insert.
            while cursor < bytes.count, bytes[cursor] == 0x20 || bytes[cursor] == 0x09 {
                cursor += 1
            }
            guard cursor + 1 < bytes.count,
                  bytes[cursor] == 0x0D, bytes[cursor + 1] == 0x0A
            else {
                throw ParseError.unterminated
            }
            cursor += 2

            guard parts.count < maxParts else { throw ParseError.tooManyParts }

            // Headers run to the first blank line.
            guard let separator = index(of: crlf + crlf, in: bytes, from: cursor) else {
                throw ParseError.malformedPart
            }
            let headerBytes = Array(bytes[cursor ..< separator])
            let bodyStart = separator + 4

            // The body runs to the CRLF that precedes the next delimiter.
            // Searching for CRLF-then-delimiter (rather than the delimiter
            // alone) is what keeps binary payloads that happen to contain
            // the boundary string from truncating the part early.
            guard let bodyEnd = index(of: crlf + delimiter, in: bytes, from: bodyStart) else {
                throw ParseError.unterminated
            }

            let headers = parseHeaders(headerBytes)
            guard let disposition = headers["content-disposition"],
                  let name = parameter("name", in: disposition)
            else {
                throw ParseError.malformedPart
            }

            parts.append(
                Part(
                    name: name,
                    filename: parameter("filename", in: disposition),
                    contentType: headers["content-type"],
                    body: ByteBuffer(bytes: bytes[bodyStart ..< bodyEnd])
                )
            )

            cursor = bodyEnd + crlf.count
        }
    }

    // MARK: - Helpers

    /// Naive substring search. Bodies here are capped in the tens of MB and
    /// needles are short, so the simple scan is not worth replacing with
    /// Boyer-Moore.
    private static func index(of needle: [UInt8], in haystack: [UInt8], from: Int) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count, from <= haystack.count - needle.count
        else { return nil }
        let first = needle[0]
        var i = from
        let last = haystack.count - needle.count
        while i <= last {
            if haystack[i] == first {
                var matched = true
                for offset in 1 ..< needle.count where haystack[i + offset] != needle[offset] {
                    matched = false
                    break
                }
                if matched { return i }
            }
            i += 1
        }
        return nil
    }

    /// Lowercased header names → values. Duplicates keep the first value;
    /// none of the headers we read are legally repeatable.
    private static func parseHeaders(_ bytes: [UInt8]) -> [String: String] {
        guard let text = String(bytes: bytes, encoding: .utf8) else { return [:] }
        var headers: [String: String] = [:]
        for line in text.components(separatedBy: "\r\n") where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex ..< colon]
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            let value = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            if headers[key] == nil { headers[key] = value }
        }
        return headers
    }

    /// Pulls `key="value"` or `key=value` out of a header value.
    private static func parameter(_ key: String, in header: String) -> String? {
        for parameter in header.split(separator: ";") {
            let trimmed = parameter.trimmingCharacters(in: .whitespaces)
            guard let equals = trimmed.firstIndex(of: "=") else { continue }
            let found = trimmed[trimmed.startIndex ..< equals]
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            guard found == key.lowercased() else { continue }

            var value = String(trimmed[trimmed.index(after: equals)...])
                .trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            return value
        }
        return nil
    }
}
