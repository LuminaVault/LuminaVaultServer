import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import SQLKit

/// Moves one vault file to a new path and re-files everything that copies its
/// location: the file row's Space, the memories compiled from it, and their
/// chunks. Shared by `POST /v1/vault/files/move` and by moving a note-backed
/// memory to another Space, so the two can never disagree about where a note
/// lives.
struct VaultFileMover {
    let fluent: Fluent
    let vaultPaths: VaultPathService

    /// `to` must already be sanitized. Throws 409 when `to` is taken.
    func move(_ row: VaultFile, to: String, tenantID: UUID) async throws {
        let db = fluent.db()
        let from = row.path
        // Reject overwrites — UNIQUE (tenant_id, path) would also reject this
        // at the DB layer, but a 409 is friendlier than a 500.
        let conflict = try await VaultFile.query(on: db, tenantID: tenantID)
            .filter(\.$path == to)
            .first()
        guard conflict == nil else {
            throw HTTPError(.conflict, message: "destination path already exists")
        }

        let rawRoot = vaultPaths.rawDirectory(for: tenantID)
        let src = try VaultController.resolveInside(rawRoot: rawRoot, relative: from)
        let dst = try VaultController.resolveInside(rawRoot: rawRoot, relative: to)

        let fm = FileManager.default
        try fm.createDirectory(
            at: dst.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fm.fileExists(atPath: src.path) {
            try fm.moveItem(at: src, to: dst)
        }
        let spaceID = try await VaultController.spaceID(forPath: to, tenantID: tenantID, db: db)
        let fileID = try row.requireID()
        row.path = to
        row.spaceID = spaceID
        try await db.transaction { tx in
            try await row.save(on: tx)
            // The folder is the Space (HER-105), so a move between folders is a
            // re-file. Memories compiled from this file and their chunks carry
            // their own copy of the Space and path; without this, a moved note
            // keeps answering Space-scoped searches for the folder it left and
            // cites a path that no longer exists.
            guard let sql = tx as? any SQLDatabase else {
                throw HTTPError(.internalServerError, message: "SQL driver required for vault move")
            }
            try await sql.raw("""
            UPDATE memories
            SET space_id = \(bind: spaceID), updated_at = NOW()
            WHERE tenant_id = \(bind: tenantID) AND source_vault_file_id = \(bind: fileID)
            """).run()
            try await sql.raw("""
            UPDATE memory_chunks
            SET space_id = \(bind: spaceID), source_path = \(bind: to)
            WHERE tenant_id = \(bind: tenantID) AND vault_file_id = \(bind: fileID)
            """).run()
        }
    }

    /// Where a file lands when re-filed into `space` (or the inbox): the
    /// Space's folder plus the file's own name, the same layout upload uses.
    static func path(forFile path: String, inSpaceSlug slug: String?) throws -> String {
        let basename = (path as NSString).lastPathComponent
        return try VaultController.sanitizePath("\(slug ?? "inbox")/\(basename)")
    }
}
