import Crypto
import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import Logging
import LuminaVaultShared

// MARK: - Server-side conformances

extension VaultUploadResponse: @retroactive ResponseEncodable {}
extension VaultFileDTO: @retroactive ResponseEncodable {}
extension VaultFileListResponse: @retroactive ResponseEncodable {}

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
            metadata: row.metadata.map {
                VaultNoteMetadataDTO(
                    title: $0.title,
                    tags: $0.tags,
                    isTodo: $0.isTodo,
                    done: $0.done,
                    dueAt: $0.dueAt
                )
            },
            createdByUserId: row.createdByUserID,
            updatedByUserId: row.updatedByUserID
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
    let initService: VaultInitService?
    let eventBus: EventBus?
    let achievements: AchievementsWorker?
    let logger: Logger
    let maxFileSize: Int
    /// HER-Notes — when present, a `?note=true` upload owns its recall memory
    /// (create-or-update by sourceVaultFileID + re-embed), and a note delete
    /// cascades that memory. Optional so non-note deployments/tests skip it.
    let memories: MemoryRepository?
    let embeddings: (any EmbeddingService)?
    let vaultAccess: VaultAccessService?

    private static let defaultLimit = 50
    private static let maxLimit = 200

    /// Decodes the `X-Vault-Metadata` note sidecar header. ISO-8601 dates so
    /// `dueAt` round-trips with the client encoder.
    private static let metadataDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    init(
        vaultPaths: VaultPathService,
        fluent: Fluent,
        initService: VaultInitService? = nil,
        eventBus: EventBus? = nil,
        achievements: AchievementsWorker? = nil,
        logger: Logger,
        maxFileSize: Int = 10 * 1024 * 1024,
        memories: MemoryRepository? = nil,
        embeddings: (any EmbeddingService)? = nil,
        vaultAccess: VaultAccessService? = nil
    ) {
        self.vaultPaths = vaultPaths
        self.fluent = fluent
        self.initService = initService
        self.eventBus = eventBus
        self.achievements = achievements
        self.logger = logger
        self.maxFileSize = maxFileSize
        self.memories = memories
        self.embeddings = embeddings
        self.vaultAccess = vaultAccess
    }

    func addRoutes(to router: RouterGroup<AppRequestContext>) {
        router.post("/files", use: upload)
        router.get("/files", use: list)
        router.post("/files/move", use: move)
        // Catch-all so subdirs in the path component (`notes/today.md`)
        // are accepted as a single parameter.
        router.delete("/files/**", use: delete)
        // HER-105 — per-file content read for the in-app Markdown reader.
        router.get("/files/**", use: read)
    }

    /// Registered on a dedicated group with a tighter rate-limit policy.
    /// See `App+build.swift` for the wiring.
    func addExportRoute(to router: RouterGroup<AppRequestContext>) {
        router.get("/export", use: export)
    }

    /// HER-35 — `/v1/vault/{create,status}`. Distinct router group so the
    /// upload rate-limit policy never applies to the init handshake.
    func addInitRoutes(to router: RouterGroup<AppRequestContext>) {
        router.post("/create", use: create)
        router.get("/status", use: status)
    }

    @Sendable
    func create(_: Request, ctx: AppRequestContext) async throws -> VaultStatusResponse {
        let user = try ctx.requireIdentity()
        guard let initService else {
            throw HTTPError(.serviceUnavailable, message: "vault init service unavailable")
        }
        return try await initService.create(for: user)
    }

    @Sendable
    func status(_: Request, ctx: AppRequestContext) async throws -> VaultStatusResponse {
        let user = try ctx.requireIdentity()
        guard let initService else {
            throw HTTPError(.serviceUnavailable, message: "vault init service unavailable")
        }
        return try await initService.status(for: user)
    }

    // MARK: - Upload

    @Sendable
    func upload(_ request: Request, ctx: AppRequestContext) async throws -> VaultUploadResponse {
        let user = try ctx.requireIdentity()
        let tenantID = try await resolvedVaultID(request, ctx: ctx, permission: .write)

        guard let rawPath = request.uri.queryParameters["path"].map(String.init), !rawPath.isEmpty else {
            throw HTTPError(.badRequest, message: "missing required query parameter `path`")
        }
        var safeRelative = try Self.sanitizePath(rawPath)

        // HER-CaptureTab — optional space association. When provided, the row
        // must belong to the caller's tenant; cross-tenant ids are rejected
        // with 400 rather than silently dropped so the Capture UI surfaces
        // the misconfiguration instead of orphaning the file.
        let spaceID = try await resolveOptionalSpaceID(
            raw: request.uri.queryParameters["space_id"].map(String.init),
            tenantID: tenantID
        )

        // HER-105 — file the upload under its Space's folder `raw/<slug>/<name>`
        // (unfiled → `raw/inbox/`), so the on-disk vault mirrors the app's
        // Spaces. The client's `path` prefix is ignored in favour of the
        // server-authoritative Space slug; only the basename is kept.
        let spaceFolder: String = if let spaceID,
                                     let space = try await Space.query(on: fluent.db(), tenantID: tenantID).filter(\.$id == spaceID).first()
        {
            space.slug
        } else {
            "inbox"
        }
        let basename = (safeRelative as NSString).lastPathComponent
        safeRelative = try Self.sanitizePath("\(spaceFolder)/\(basename)")

        let contentType = request.headers[.contentType] ?? "application/octet-stream"
        try Self.validateContentType(contentType, againstExtension: (safeRelative as NSString).pathExtension.lowercased())

        // HER-Notes — optional note/todo sidecar passed as a JSON header so the
        // raw-bytes body stays the file payload. Malformed JSON is ignored
        // (the upload still succeeds as a plain file) rather than 400'ing.
        let noteMetadata: VaultFileMetadata? = request.headers[.init("X-Vault-Metadata")!]
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? Self.metadataDecoder.decode(VaultFileMetadata.self, from: $0) }

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
            withIntermediateDirectories: true
        )
        let tmp = target.appendingPathExtension("tmp-\(UUID().uuidString.prefix(8))")
        try data.write(to: tmp, options: .atomic)
        if fm.fileExists(atPath: target.path) {
            try fm.removeItem(at: target)
        }
        try fm.moveItem(at: tmp, to: target)

        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        // HER-105 — `?processed=true` marks the row already-compiled (written
        // text notes set this; they create their memory via /v1/memory/upsert).
        let processed = request.uri.queryParameters["processed"].map(String.init) == "true"
        let savedID = try await upsertVaultFileRow(
            tenantID: tenantID,
            spaceID: spaceID,
            path: safeRelative,
            contentType: contentType,
            sizeBytes: Int64(data.count),
            sha256: digest,
            processed: processed,
            metadata: noteMetadata
        )
        if let row = try await VaultFile.find(savedID, on: fluent.db()) {
            let actorID = try user.requireID()
            row.createdByUserID = row.createdByUserID ?? actorID
            row.updatedByUserID = actorID
            try await row.update(on: fluent.db())
        }
        logger.info("vault upload tenant=\(tenantID) path=\(safeRelative) bytes=\(data.count)")

        if let achievements {
            achievements.enqueue(tenantID: tenantID, event: .vaultUploaded)
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
                ]
            )
            eventBus.publish(event)
        }

        // HER-Notes — a written note (`?note=true`) owns its recall memory
        // right here, so creation and every later edit re-embed in one call
        // (no separate /v1/memory/upsert, no lineage gap). Create-or-update
        // is keyed on the vault file id; tags ride the metadata sidecar.
        // Failures are logged, not fatal — the file write already succeeded.
        let isNote = request.uri.queryParameters["note"].map(String.init) == "true"
        PostHogAnalytics.capture("vault_file_uploaded", properties: [
            "content_type": contentType,
            "is_note": isNote,
            "has_space": spaceID != nil,
        ])
        if isNote, let memories, let embeddings,
           let content = String(data: data, encoding: .utf8), !content.isEmpty
        {
            do {
                let embedding = try await embeddings.embed(content, tenantID: tenantID)
                if let existingMemID = try await memories.idBySourceVaultFileID(
                    tenantID: tenantID, sourceVaultFileID: savedID
                ) {
                    _ = try await memories.updateContent(
                        tenantID: tenantID, id: existingMemID,
                        content: content, embedding: embedding
                    )
                } else {
                    _ = try await memories.create(
                        tenantID: tenantID,
                        content: content,
                        embedding: embedding,
                        tags: noteMetadata?.tags,
                        sourceVaultFileID: savedID,
                        spaceID: spaceID,
                        reviewState: "auto"
                    )
                }
            } catch {
                logger.error("note memory upsert failed tenant=\(tenantID) path=\(safeRelative): \(error)")
            }
        }

        return VaultUploadResponse(
            path: safeRelative,
            size: data.count,
            contentType: contentType,
            sha256: digest
        )
    }

    // MARK: - List

    @Sendable
    func list(_ request: Request, ctx: AppRequestContext) async throws -> VaultFileListResponse {
        let tenantID = try await resolvedVaultID(request, ctx: ctx, permission: .read)

        let limit = Self.clamp(
            request.uri.queryParameters["limit"].flatMap { Int($0) } ?? Self.defaultLimit,
            min: 1, max: Self.maxLimit
        )
        let before = request.uri.queryParameters["before"].flatMap { Self.parseISODate(String($0)) }
        let after = request.uri.queryParameters["after"].flatMap { Self.parseISODate(String($0)) }
        let spaceSlug = request.uri.queryParameters["space"].map(String.init)
        // HER-105 — filename substring search for the vault browser's
        // top search bar. Case-insensitive `ILIKE` on the `path` column.
        // No trigram index yet (pg_trgm) — scale doesn't warrant it.
        let q = request.uri.queryParameters["q"].map(String.init).flatMap { $0.isEmpty ? nil : $0 }

        // Inbox = unfiled notes (spaceID nil). `space=inbox` is a reserved
        // sentinel — no real Space row has that slug; uploads use "inbox"
        // only as the on-disk folder for unfiled files. `unfiled=true` is an
        // explicit alias. Either path filters `space_id IS NULL` rather than
        // resolving a slug (which would 404).
        let unfiled = request.uri.queryParameters["unfiled"].map(String.init) == "true"
            || spaceSlug == "inbox"

        var spaceID: UUID?
        if !unfiled, let slug = spaceSlug, !slug.isEmpty {
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
        if unfiled {
            _ = query.filter(\.$spaceID == nil)
        } else if let spaceID {
            _ = query.filter(\.$spaceID == spaceID)
        }
        if let q {
            // SQL ILIKE wildcard match. Escape `%` and `_` so a user
            // searching for them doesn't accidentally widen the match.
            let escaped = q.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%")
                .replacingOccurrences(of: "_", with: "\\_")
            _ = query.filter(\.$path, .custom("ILIKE"), "%\(escaped)%")
        }

        let rows = try await query.all()
        let dtos = try rows.map(VaultFileDTO.fromRow)
        return VaultFileListResponse(
            files: dtos,
            limit: limit,
            nextBefore: rows.count == limit ? rows.last?.createdAt : nil
        )
    }

    // MARK: - Read (HER-105)

    /// `GET /v1/vault/files/<path>` — streams the raw bytes for a single
    /// tenant-owned file. Used by the iOS vault browser's Markdown reader.
    /// Returns 404 if the DB row is absent **or** the file is no longer on
    /// disk (covers the soft-deleted state where the row is gone but the
    /// `_deleted_*` mirror still exists).
    @Sendable
    func read(_ request: Request, ctx: AppRequestContext) async throws -> Response {
        let tenantID = try await resolvedVaultID(request, ctx: ctx, permission: .read)

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
        let fm = FileManager.default
        guard fm.fileExists(atPath: target.path) else {
            throw HTTPError(.notFound, message: "vault file body missing")
        }

        let data = try Data(contentsOf: target)
        var headers = HTTPFields()
        headers[.contentType] = row.contentType
        headers[.contentLength] = String(data.count)
        return Response(
            status: .ok,
            headers: headers,
            body: ResponseBody(byteBuffer: ByteBuffer(data: data))
        )
    }

    // MARK: - Delete (soft)

    @Sendable
    func delete(_ request: Request, ctx: AppRequestContext) async throws -> Response {
        let tenantID = try await resolvedVaultID(request, ctx: ctx, permission: .write)

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
        // HER-Notes — cascade the note's recall memory so a delete doesn't
        // leave a dangling memory whose source file is gone. No-op for files
        // that never produced a note memory. Captured before row.delete since
        // M23's FK is ON DELETE SET NULL (which would orphan, not remove).
        if let memories, let rowID = try? row.requireID() {
            try? await memories.deleteBySourceVaultFileID(tenantID: tenantID, sourceVaultFileID: rowID)
        }
        try await row.delete(on: fluent.db())
        logger.info("vault delete tenant=\(tenantID) path=\(safeRelative)")
        PostHogAnalytics.capture("vault_file_deleted")
        return Response(status: .noContent)
    }

    // MARK: - Move

    @Sendable
    func move(_ request: Request, ctx: AppRequestContext) async throws -> VaultFileDTO {
        let tenantID = try await resolvedVaultID(request, ctx: ctx, permission: .write)

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
            withIntermediateDirectories: true
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
            logger: logger
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

    private func resolvedVaultID(
        _ request: Request,
        ctx: AppRequestContext,
        permission: VaultPermission
    ) async throws -> UUID {
        if let vaultAccess {
            return try await vaultAccess.resolve(request: request, context: ctx, requiring: permission).vaultID
        }
        return try ctx.requireTenantID()
    }

    /// Returns the row id of the upserted vault file so the upload handler
    /// can include it in the `vault_file_created` event payload (HER-171).
    /// `spaceID` is propagated from the optional `space_id` upload query
    /// param. On re-upload to an existing path, a provided `spaceID`
    /// overwrites the prior value; `nil` leaves the existing association
    /// untouched so a content update doesn't accidentally unfile the row.
    private func upsertVaultFileRow(
        tenantID: UUID,
        spaceID: UUID?,
        path: String,
        contentType: String,
        sizeBytes: Int64,
        sha256: String,
        processed: Bool = false,
        metadata: VaultFileMetadata? = nil
    ) async throws -> UUID {
        let db = fluent.db()
        // HER-105 — `processed` marks the row already-compiled so Sync & Learn
        // skips it. Used by written text notes, which create their memory
        // immediately via `/v1/memory/upsert`; without this the note's markdown
        // file would be re-compiled into a duplicate memory.
        let processedAt: Date? = processed ? Date() : nil
        if let existing = try await VaultFile.query(on: db, tenantID: tenantID)
            .filter(\.$path == path)
            .first()
        {
            existing.contentType = contentType
            existing.sizeBytes = sizeBytes
            existing.sha256 = sha256
            existing.processedAt = processedAt
            if let spaceID {
                existing.spaceID = spaceID
            }
            if let metadata {
                existing.metadata = Self.mergeMetadata(existing.metadata, metadata)
            }
            try await existing.save(on: db)
            return try existing.requireID()
        }
        let row = VaultFile(
            tenantID: tenantID,
            spaceID: spaceID,
            path: path,
            contentType: contentType,
            sizeBytes: sizeBytes,
            sha256: sha256,
            processedAt: processedAt,
            metadata: metadata
        )
        try await row.save(on: db)
        return try row.requireID()
    }

    /// Merge note metadata over an existing sidecar. The incoming note fields
    /// (title/tags/isTodo/done/dueAt) overwrite; `enrichmentStatus` is owned
    /// by the enrichment pipeline, so it survives a note edit that doesn't
    /// carry one.
    private static func mergeMetadata(
        _ old: VaultFileMetadata?,
        _ new: VaultFileMetadata
    ) -> VaultFileMetadata {
        VaultFileMetadata(
            enrichmentStatus: new.enrichmentStatus ?? old?.enrichmentStatus,
            title: new.title,
            tags: new.tags,
            isTodo: new.isTodo,
            done: new.done,
            dueAt: new.dueAt,
            projectID: new.projectID ?? old?.projectID
        )
    }

    /// Parses the optional `space_id` upload query param and confirms it
    /// belongs to `tenantID`. nil-in / nil-out is the unfiled path; a
    /// malformed UUID or cross-tenant id both raise 400 so the client
    /// sees the misconfiguration instead of silently dropping the link.
    private func resolveOptionalSpaceID(raw: String?, tenantID: UUID) async throws -> UUID? {
        guard let raw, !raw.isEmpty else { return nil }
        guard let spaceID = UUID(uuidString: raw) else {
            throw HTTPError(.badRequest, message: "`space_id` is not a valid UUID")
        }
        let exists = try await Space.query(on: fluent.db(), tenantID: tenantID)
            .filter(\.$id == spaceID)
            .first()
        guard exists != nil else {
            throw HTTPError(.badRequest, message: "`space_id` does not belong to the caller")
        }
        return spaceID
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
        if let d = withFractional.date(from: raw) {
            return d
        }
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
        // HER-34: iOS Photos Picker default. Accept `image/heif` as an
        // alias because iOS sometimes labels HEIC files with the
        // container MIME (`image/heif`) and sometimes the codec MIME
        // (`image/heic`).
        "heic": ["image/heic", "image/heif"],
        "heif": ["image/heif", "image/heic"],
        "pdf": ["application/pdf"],
        "mp3": ["audio/mpeg", "audio/mp3"],
        "m4a": ["audio/mp4", "audio/x-m4a"],
        "aac": ["audio/aac"],
        "wav": ["audio/wav", "audio/x-wav"],
        "flac": ["audio/flac", "audio/x-flac"],
        "mp4": ["video/mp4"],
        "mov": ["video/quicktime"],
        "webm": ["video/webm"],
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
