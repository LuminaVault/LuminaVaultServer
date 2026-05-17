import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import Logging

enum SpacesError {
    static let invalidSlug = HTTPError(.badRequest, message: "slug must be 2-31 chars, lowercase a-z/0-9/-, no leading dash")
    static let slugTaken = HTTPError(.conflict, message: "slug already used in this vault")
    static let notFound = HTTPError(.notFound, message: "space not found")
    static let nameRequired = HTTPError(.badRequest, message: "name required")
}

enum SpaceSlugPolicy {
    static let pattern = #"^[a-z0-9][a-z0-9-]{1,30}$"#
    static let reserved: Set<String> = ["raw", "compiled", "trash", "_deleted", "tmp"]

    static func validate(_ raw: String) throws -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard s.range(of: pattern, options: .regularExpression) != nil,
              !reserved.contains(s)
        else { throw SpacesError.invalidSlug }
        return s
    }
}

/// CRUD for user-defined organizing folders. DB row is the source of truth;
/// the on-disk folder under `<rawRoot>/<slug>/` is created on insert and
/// soft-deleted on remove. Slug is locked at create time — display `name`
/// is mutable, but the path stays stable so existing notes don't move.
struct SpacesService {
    let fluent: Fluent
    let vaultPaths: VaultPathService
    let logger: Logger

    func list(tenantID: UUID) async throws -> [Space] {
        try await Space.query(on: fluent.db(), tenantID: tenantID)
            .sort(\.$name, .ascending)
            .all()
    }

    func get(tenantID: UUID, id: UUID) async throws -> Space {
        guard let space = try await Space.query(on: fluent.db(), tenantID: tenantID)
            .filter(\.$id == id)
            .first()
        else { throw SpacesError.notFound }
        return space
    }

    func create(
        tenantID: UUID,
        name: String,
        slugRaw: String,
        description: String?,
        color: String?,
        icon: String?,
        category: String? = nil,
    ) async throws -> Space {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw SpacesError.nameRequired }
        let slug = try SpaceSlugPolicy.validate(slugRaw)

        let db = fluent.db()
        if try await Space.query(on: db, tenantID: tenantID)
            .filter(\.$slug == slug)
            .first() != nil
        {
            throw SpacesError.slugTaken
        }

        try vaultPaths.ensureTenantDirectories(for: tenantID)
        let folder = vaultPaths.rawDirectory(for: tenantID).appendingPathComponent(slug)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let space = Space(
            tenantID: tenantID,
            name: trimmedName,
            slug: slug,
            description: description,
            color: color,
            icon: icon,
            category: category?.isEmpty == true ? nil : category,
        )
        do {
            try await space.save(on: db)
        } catch {
            // DB write lost — clean up the empty folder we just made.
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        logger.info("space created tenant=\(tenantID) slug=\(slug)")
        return space
    }

    /// nil means "don't touch"; non-nil means "set". Pass empty string to
    /// clear an optional field (description / color / icon / category).
    func update(
        tenantID: UUID,
        id: UUID,
        name: String?,
        description: String?,
        color: String?,
        icon: String?,
        category: String? = nil,
    ) async throws -> Space {
        let space = try await get(tenantID: tenantID, id: id)
        if let name {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw SpacesError.nameRequired }
            space.name = trimmed
        }
        if let description { space.spaceDescription = description.isEmpty ? nil : description }
        if let color { space.color = color.isEmpty ? nil : color }
        if let icon { space.icon = icon.isEmpty ? nil : icon }
        if let category { space.category = category.isEmpty ? nil : category }
        try await space.save(on: fluent.db())
        return space
    }

    /// Seeded on first `POST /v1/vault/create`. Slugs are reserved
    /// product-defaults and stable across users so the client can render
    /// known category icons on first launch. Idempotent: skips any slug
    /// the tenant already owns. Returns the list of slugs actually
    /// created in this call (already-present slugs are not re-reported).
    @discardableResult
    func seedDefaults(tenantID: UUID) async throws -> [String] {
        var created: [String] = []
        for entry in SpaceDefaults.entries {
            do {
                _ = try await create(
                    tenantID: tenantID,
                    name: entry.name,
                    slugRaw: entry.slug,
                    description: nil,
                    color: nil,
                    icon: entry.icon,
                    category: entry.slug,
                )
                created.append(entry.slug)
            } catch let httpError as HTTPError where httpError.status == .conflict {
                // Slug already owned by this tenant — re-run of vault create
                // (idempotent) or a manual create that won the race. Skip.
                continue
            }
        }
        return created
    }

    func delete(tenantID: UUID, id: UUID) async throws {
        let space = try await get(tenantID: tenantID, id: id)
        let folder = vaultPaths.rawDirectory(for: tenantID).appendingPathComponent(space.slug)
        // Soft-remove on disk so we don't lose user notes if this was an oops.
        if FileManager.default.fileExists(atPath: folder.path) {
            let stamp = Int(Date().timeIntervalSince1970)
            let stamped = vaultPaths.rawDirectory(for: tenantID)
                .appendingPathComponent("_deleted_\(stamp)_\(space.slug)")
            try FileManager.default.moveItem(at: folder, to: stamped)
            logger.info("space folder soft-deleted: \(space.slug) -> \(stamped.lastPathComponent)")
        }
        try await space.delete(on: fluent.db())
    }
}
