import Crypto
import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import Logging
import LuminaVaultShared

// MARK: - Server-side conformances

extension VaultUploadResponse: ResponseEncodable {}
extension VaultFileDTO: ResponseEncodable {}
extension VaultFileListResponse: ResponseEncodable {}

// MARK: - Server-local request DTOs

struct VaultMoveRequest: Codable {
    let path: String
    let newPath: String
}

/// Server-only: convenience init from the Fluent `VaultFile` model.
extension VaultFileDTO {
    static func fromRow(_ row: VaultFile) throws -> VaultFileDTO {
        try VaultFileDTO(
            id: row.requireID(),
            path: row.path,
            contentType: row.contentType,
            sizeBytes: row.sizeBytes,
            sha256: row.sha256,
            spaceId: row.spaceID,
            createdAt: row.createdAt,
            updatedAt: row.updatedAt,
        )
    }
}

/// - `GET    /v1/vault/files`                     — paginated list (HER-88)
/// - `DELETE /v1/vault/files/**`                  — soft-delete (HER-88)
/// - `POST   /v1/vault/files/move`                — rename within tenant root (HER-88)
///
/// Hermes reads the same `<tenantRoot>` via the `./data/hermes` bind mount
/// when `vault.rootPath` and `hermes.dataRoot` point at the same host dir,
/// so uploaded notes are immediately visible to the per-user profile.
struct VaultController {
    let vaultPaths: VaultPathService
    let fluent: Fluent
    let eventBus: EventBus?
    let achievements: AchievementsService?
    let logger: Logger
    let maxFileSize: Int

    private static let defaultLimit = 50
    private static let maxLimit = 200

    init(
        vaultPaths: VaultPathService,
        fluent: Fluent,
        eventBus: EventBus? = nil,
        achievements: AchievementsService? = nil,
        logger: Logger,
        maxFileSize: Int = 10 * 1024 * 1024,
    ) {
        self.vaultPaths = vaultPaths
        self.fluent = fluent
        self.eventBus = eventBus
        self.achievements = achievements
        self.logger = logger
        self.maxFileSize = maxFileSize
    }

    func addRoutes(to router: RouterGroup<AppRequestContext>) {
        router.post("/files", use: upload)
        router.get("/files", use: list)
        router.post("/files/move", use: move)
        // Catch-all so subdirs in the path component (`notes/today.md`)
        // are accepted as a single parameter.
        router.delete("/files/**", use: delete)
    }

    /// Registered on a dedicated group with a tighter rate-limit policy.
    /// See `App+build.swift` for the wiring.
    func addExportRoute(to router: RouterGroup<AppRequestContext>) {
        router.get("/export", use: export)
    }

    // MARK: - Upload

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
        let target = try Self.resolveInside(rawRoot: rawRoot, relative: safeRelative)

        let fm = FileManager.default
        try fm.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true,
        )
        let tmp = target.appendingPathExtension("tmp-\(UUID().uuidString.prefix(8))")
        try data.write(to: tmp, options: .atomic)
        if fm.fileExists(atPath: target.path) {
            try fm.removeItem(at: target)
        }
        try fm.moveItem(at: tmp, to: target)

        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let savedID = try await upsertVaultFileRow(
            tenantID: tenantID,
            path: safeRelative,
            contentType: contentType,
            sizeBytes: Int64(data.count),
            sha256: digest,
        )
        logger.info("vault upload tenant=\(tenantID) path=\(safeRelative) bytes=\(data.count)")

        if let achievements {
            Task.detached { await achievements.recordAndPush(tenantID: tenantID, event: .vaultUploaded) }
        }

        // HER-171: notify the skills runtime so capture-driven skills
        // (e.g. capture-enrich) can fire on new vault writes. Fire-and-
        // forget — the bus is in-process and never throws.
        if let eventBus {
            let event = SkillEvent(
                type: .vaultFileCreated,
                tenantID: tenantID,
                payload: [
                    SkillEvent.PayloadKey.vaultFileID: savedID.uuidString,
                    SkillEvent.PayloadKey.vaultPath: safeRelative,
                ],
            )
            await eventBus.publish(event)
        }

        return VaultUploadResponse(
            path: safeRelative,
            size: data.count,
            contentType: contentType,
            sha256: digest,
        )
    }

    // MARK: - List

    @Sendable
    func list(_ request: Request, ctx: AppRequestContext) async throws -> VaultFileListResponse {
        let user = try ctx.requireIdentity()
        let tenantID = try user.requireID()

        let limit = Self.clamp(
            request.uri.queryParameters["limit"].flatMap { Int($0) } ?? Self.defaultLimit,
            min: 1, max: Self.maxLimit,
        )
        let before = request.uri.queryParameters["before"].flatMap { Self.parseISODate(String($0)) }
        let after = request.uri.queryParameters["after"].flatMap { Self.parseISODate(String($0)) }
        let spaceSlug = request.uri.queryParameters["space"].map(String.init)

        var spaceID: UUID?
        if let slug = spaceSlug, !slug.isEmpty {
            let space = try await Space.query(on: fluent.db(), tenantID: tenantID)
                .filter(\.$slug == slug)
                .first()
            guard let space else {
                throw HTTPError(.notFound, message: "unknown space `\(slug)`")
            }
            spaceID = try space.requireID()
        }

        let query = VaultFile.query(on: fluent.db(), tenantID: tenantID)
            .sort(\.$createdAt, .descending)
            .sort(\.$id, .descending)
            .limit(limit)
        if let before {
            _ = query.filter(\.$createdAt < before)
        }
        if let after {
            _ = query.filter(\.$createdAt > after)
        }
        if let spaceID {
            _ = query.filter(\.$spaceID == spaceID)
        }

        let rows = try await query.all()
        let dtos = try rows.map(VaultFileDTO.fromRow)
        return VaultFileListResponse(
            files: dtos,
            limit: limit,
            nextBefore: rows.count == limit ? rows.last?.createdAt : nil,
        )
    }

    // MARK: - Delete (soft)

    @Sendable
    func delete(_: Request, ctx: AppRequestContext) async throws -> Response {
        let user = try ctx.requireIdentity()
        let tenantID = try user.requireID()

        // Hummingbird's `**` glob lands in `parameters["catchall"]` as the
        // remaining path slash-joined. Re-sanitize before doing anything.
        guard let rawPath: String = ctx.parameters.getCatchAll().joined(separator: "/").nonEmpty else {
            throw HTTPError(.badRequest, message: "missing path")
        }
        let safeRelative = try Self.sanitizePath(rawPath)

        let row = try await VaultFile.query(on: fluent.db(), tenantID: tenantID)
            .filter(\.$path == safeRelative)
            .first()
        guard let row else {
            throw HTTPError(.notFound, message: "vault file not found")
        }

        let rawRoot = vaultPaths.rawDirectory(for: tenantID)
        let target = try Self.resolveInside(rawRoot: rawRoot, relative: safeRelative)

        let ts = Int(Date().timeIntervalSince1970)
        let flattened = safeRelative.replacingOccurrences(of: "/", with: "_")
        let trashTarget = rawRoot.appendingPathComponent("_deleted_\(ts)_\(flattened)")

        let fm = FileManager.default
        if fm.fileExists(atPath: target.path) {
            do {
                try fm.moveItem(at: target, to: trashTarget)
            } catch {
                // Best-effort. The DB row is the source of truth for the
                // user-visible state; never block deletion on a disk hiccup.
                logger.error("vault soft-delete rename failed tenant=\(tenantID) path=\(safeRelative): \(error)")
            }
        }
        try await row.delete(on: fluent.db())
        logger.info("vault delete tenant=\(tenantID) path=\(safeRelative)")
        return Response(status: .noContent)
    }

    // MARK: - Move

    @Sendable
    func move(_ request: Request, ctx: AppRequestContext) async throws -> VaultFileDTO {
        let user = try ctx.requireIdentity()
        let tenantID = try user.requireID()

        let body = try await request.decode(as: VaultMoveRequest.self, context: ctx)
        let from = try Self.sanitizePath(body.path)
        let to = try Self.sanitizePath(body.newPath)
        guard from != to else {
            throw HTTPError(.badRequest, message: "path and newPath are identical")
        }

        let db = fluent.db()
        let row = try await VaultFile.query(on: db, tenantID: tenantID)
            .filter(\.$path == from)
            .first()
        guard let row else {
            throw HTTPError(.notFound, message: "vault file not found")
        }
        // Reject overwrites — UNIQUE (tenant_id, path) would also reject this
        // at the DB layer, but a 409 is friendlier than a 500.
        let conflict = try await VaultFile.query(on: db, tenantID: tenantID)
            .filter(\.$path == to)
            .first()
        guard conflict == nil else {
            throw HTTPError(.conflict, message: "destination path already exists")
        }

        let rawRoot = vaultPaths.rawDirectory(for: tenantID)
        let src = try Self.resolveInside(rawRoot: rawRoot, relative: from)
        let dst = try Self.resolveInside(rawRoot: rawRoot, relative: to)

        let fm = FileManager.default
        try fm.createDirectory(
            at: dst.deletingLastPathComponent(),
            withIntermediateDirectories: true,
        )
        if fm.fileExists(atPath: src.path) {
            try fm.moveItem(at: src, to: dst)
        }
        row.path = to
        try await row.save(on: db)
        logger.info("vault move tenant=\(tenantID) from=\(from) to=\(to)")
        return try VaultFileDTO.fromRow(row)
    }

    // MARK: - Export (HER-91)

    /// Streaming `application/zip` of the tenant's vault. Optional `since`
    /// query parameter (ISO-8601) filters to files modified at-or-after the
    /// instant. The archive root contains `SOUL.md`, `memories.json`, and
    /// every file under `raw/`.
    @Sendable
    func export(_ request: Request, ctx: AppRequestContext) async throws -> Response {
        let user = try ctx.requireIdentity()
        let since = request.uri.queryParameters["since"].flatMap { Self.parseISODate(String($0)) }

        let exporter = VaultExportService(
            vaultPaths: vaultPaths,
            fluent: fluent,
            logger: logger,
        )
        let capturedUser = user
        let body = ResponseBody { writer in
            try await exporter.streamExport(user: capturedUser, since: since, writer: &writer)
            try await writer.finish(nil)
        }
        let tenantID = try user.requireID()
        var headers = HTTPFields()
        headers[.contentType] = "application/zip"
        headers[.contentDisposition] = "attachment; filename=\"vault-\(tenantID.uuidString).zip\""
        return Response(status: .ok, headers: headers, body: body)
    }

    // MARK: - DB helpers

    /// Returns the row id of the upserted vault file so the upload handler
    /// can include it in the `vault_file_created` event payload (HER-171).
    private func upsertVaultFileRow(
        tenantID: UUID,
        path: String,
        contentType: String,
        sizeBytes: Int64,
        sha256: String,
    ) async throws -> UUID {
        let db = fluent.db()
        if let existing = try await VaultFile.query(on: db, tenantID: tenantID)
            .filter(\.$path == path)
            .first()
        {
            existing.contentType = contentType
            existing.sizeBytes = sizeBytes
            existing.sha256 = sha256
            existing.processedAt = nil
            try await existing.save(on: db)
            return try existing.requireID()
        }
        let row = VaultFile(
            tenantID: tenantID,
            path: path,
            contentType: contentType,
            sizeBytes: sizeBytes,
            sha256: sha256,
        )
        try await row.save(on: db)
        return try row.requireID()
    }

    // MARK: - Path resolution

    /// Joins `relative` onto `rawRoot` and asserts the canonical result stays
    /// inside `rawRoot`. Defense-in-depth against symlink and `..` escape
    /// even after `sanitizePath` (e.g. a symlink planted out of band).
    static func resolveInside(rawRoot: URL, relative: String) throws -> URL {
        let target = rawRoot.appendingPathComponent(relative)
        let resolved = target.standardizedFileURL.path
        let rootPrefix = rawRoot.standardizedFileURL.path + "/"
        guard resolved.hasPrefix(rootPrefix) else {
            throw HTTPError(.badRequest, message: "resolved path escapes vault root")
        }
        return target
    }

    private static func clamp(_ value: Int, min lo: Int, max hi: Int) -> Int {
        Swift.max(lo, Swift.min(hi, value))
    }

    /// Parses ISO-8601 timestamps from the `before` / `after` query string.
    /// `ISO8601DateFormatter` is non-`Sendable`, so we instantiate per call —
    /// list endpoints are not hot enough for this to matter, and it sidesteps
    /// the global-mutable-state diagnostic on strict-concurrency builds.
    private static func parseISODate(_ raw: String) -> Date? {
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFractional.date(from: raw) { return d }
        let plain = ISO8601DateFormatter()
        return plain.date(from: raw)
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
        "gif": ["image/gif"],
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

private extension String {
    /// Returns `nil` for empty strings; useful in `guard let` chains.
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
