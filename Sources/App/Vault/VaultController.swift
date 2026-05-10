import Crypto
import Foundation
import Hummingbird
import Logging

struct VaultUploadResponse: Codable, ResponseEncodable, Sendable {
    let path: String
    let size: Int
    let contentType: String
    let sha256: String
}

/// Per-tenant file uploads to the raw vault directory.
///
/// Layout: `<vaultRoot>/tenants/<userID>/raw/<path>`
///
/// Request shape:
/// - `POST /v1/vault/files?path=notes/today.md` (path may include subdirs)
/// - `Content-Type` is whitelisted (text/markdown, image/*).
/// - Body is the raw file bytes, capped at `maxFileSize`.
///
/// Hermes reads the same `<tenantRoot>` via the `./data/hermes` bind mount
/// when `vault.rootPath` and `hermes.dataRoot` point at the same host dir,
/// so uploaded notes are immediately visible to the per-user profile.
struct VaultController {
    let vaultPaths: VaultPathService
    let logger: Logger
    let maxFileSize: Int

    init(vaultPaths: VaultPathService, logger: Logger, maxFileSize: Int = 10 * 1024 * 1024) {
        self.vaultPaths = vaultPaths
        self.logger = logger
        self.maxFileSize = maxFileSize
    }

    func addRoutes(to router: RouterGroup<AppRequestContext>) {
        router.post("/files", use: upload)
    }

    @Sendable
    func upload(_ request: Request, ctx: AppRequestContext) async throws -> VaultUploadResponse {
        let user = try ctx.requireIdentity()
        let tenantID = try user.requireID()

        guard let rawPath = request.uri.queryParameters["path"].map(String.init), !rawPath.isEmpty else {
            throw HTTPError(.badRequest, message: "missing required query parameter `path`")
        }
        let safeRelative = try Self.sanitizePath(rawPath)

        let contentType = request.headers[.contentType] ?? "application/octet-stream"
        try Self.validateContentType(contentType, againstExtension: (safeRelative as NSString).pathExtension.lowercased())

        var mutableRequest = request
        let buffer = try await mutableRequest.collectBody(upTo: maxFileSize)
        let data = Data(buffer: buffer)
        guard !data.isEmpty else {
            throw HTTPError(.badRequest, message: "empty body")
        }

        try vaultPaths.ensureTenantDirectories(for: tenantID)
        let rawRoot = vaultPaths.rawDirectory(for: tenantID)
        let target = rawRoot.appendingPathComponent(safeRelative)

        // Defense-in-depth: the resolved target must still sit inside rawRoot
        // even after symlink expansion. Use standardizedFileURL which resolves
        // `..` components and absolute jumps.
        let resolvedTarget = target.standardizedFileURL.path
        let rawRootPrefix = rawRoot.standardizedFileURL.path + "/"
        guard resolvedTarget.hasPrefix(rawRootPrefix) else {
            throw HTTPError(.badRequest, message: "resolved path escapes vault root")
        }

        let fm = FileManager.default
        try fm.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let tmp = target.appendingPathExtension("tmp-\(UUID().uuidString.prefix(8))")
        try data.write(to: tmp, options: .atomic)
        if fm.fileExists(atPath: target.path) {
            try fm.removeItem(at: target)
        }
        try fm.moveItem(at: tmp, to: target)

        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        logger.info("vault upload tenant=\(tenantID) path=\(safeRelative) bytes=\(data.count)")

        return VaultUploadResponse(
            path: safeRelative,
            size: data.count,
            contentType: contentType,
            sha256: digest
        )
    }

    // MARK: - Validation

    /// Allowed file extensions and the content-type prefix(es) they accept.
    private static let allowedExtensions: [String: Set<String>] = [
        "md": ["text/markdown", "text/x-markdown", "text/plain"],
        "markdown": ["text/markdown", "text/x-markdown", "text/plain"],
        "txt": ["text/plain"],
        "png": ["image/png"],
        "jpg": ["image/jpeg"],
        "jpeg": ["image/jpeg"],
        "webp": ["image/webp"],
        "gif": ["image/gif"]
    ]

    static func sanitizePath(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 512 else {
            throw HTTPError(.badRequest, message: "path empty or too long")
        }
        guard !trimmed.hasPrefix("/") else {
            throw HTTPError(.badRequest, message: "path must be relative")
        }
        let segments = trimmed.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !segments.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw HTTPError(.badRequest, message: "path contains illegal segment")
        }
        let allowedChars = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: "._-"))
        for segment in segments {
            guard segment.unicodeScalars.allSatisfy({ allowedChars.contains($0) }) else {
                throw HTTPError(.badRequest, message: "path contains illegal characters")
            }
        }
        let ext = (trimmed as NSString).pathExtension.lowercased()
        guard allowedExtensions.keys.contains(ext) else {
            throw HTTPError(.badRequest, message: "unsupported file extension `\(ext)`")
        }
        return trimmed
    }

    static func validateContentType(_ contentType: String, againstExtension ext: String) throws {
        guard let allowed = allowedExtensions[ext] else {
            throw HTTPError(.badRequest, message: "unsupported file extension `\(ext)`")
        }
        // Strip charset / boundary parameters before comparing.
        let mime = contentType
            .split(separator: ";")
            .first
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            ?? contentType.lowercased()
        guard allowed.contains(mime) else {
            throw HTTPError(.unsupportedMediaType, message: "Content-Type `\(mime)` not allowed for `.\(ext)`")
        }
    }
}
