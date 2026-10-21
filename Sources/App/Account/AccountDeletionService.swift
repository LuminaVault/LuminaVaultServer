import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import Logging
import SQLKit

/// HER-92: GDPR / CCPA account-deletion service.
///
/// Flow:
///   1. Re-auth gate — caller must supply `password` (verified against the bcrypt hash)
///      OR present a JWT whose `iat` is within `freshAuthWindow` (default 5 minutes).
///      OAuth-only users with no remembered password use the fresh-JWT path: log in
///      again immediately before calling DELETE.
///   2. In one transaction: erase the tenant rows no cascade reaches
///      (`TenantDataEraser` — agent rooms, the device command queue,
///      idempotency replays, telemetry, spend buckets; billing records are
///      anonymized, not deleted), then drop the `users` row. Every other
///      per-tenant table has `ON DELETE CASCADE` on `users(id)` (refresh
///      tokens, memories, hermes_profile, vault_files, spaces, …), so the
///      delete wipes them atomically with the rest.
///   3. Soft-delete on-disk artifacts — rename `<vaultRoot>/tenants/<id>` and
///      `<hermesDataRoot>/profiles/<hermesProfileID>` to `_deleted_<ts>_<id>` siblings,
///      where `<ts>` is Unix seconds. `DeletedDataPurgeService` permanently
///      removes them once older than `account.deletion.purgeAfterDays`
///      (default 30); the window exists so an operator can recover from a
///      mistaken deletion. A rename that fails is logged and the directory
///      stays where it was — nothing purges it, so that log line needs a human.
///   4. Audit log — `tenantID` only. NEVER log the deleted user's email,
///      username, or any payload field (GDPR right-to-erasure includes audit
///      trails that re-leak the data).
struct AccountDeletionService {
    let fluent: Fluent
    let hasher: any PasswordHasher
    let vaultPaths: VaultPathService
    let hermesDataRoot: String
    let logger: Logger

    /// Window during which a previously-issued JWT counts as "fresh re-auth"
    /// without a password. 5 minutes matches the iOS settings-screen flow:
    /// user signs in, navigates to delete-account, confirms.
    var freshAuthWindow: TimeInterval = 5 * 60

    func deleteAccount(
        user: User,
        password: String?,
        tokenIssuedAt: Date?,
        now: Date = Date()
    ) async throws {
        let tenantID = try user.requireID()

        try await verifyReAuth(
            user: user, password: password, tokenIssuedAt: tokenIssuedAt, now: now
        )

        // Capture Hermes profile id BEFORE the cascade wipes the row.
        let hermesProfileID = try await HermesProfile
            .query(on: fluent.db(), tenantID: tenantID)
            .first()?
            .hermesProfileID

        try await fluent.db().transaction { tx in
            guard let sql = tx as? any SQLDatabase else {
                throw HTTPError(.internalServerError, message: "account deletion requires SQL")
            }
            try await TenantDataEraser.erase(tenantID: tenantID, on: sql)
            // CASCADE drops every FK-owned row in the remaining child tables.
            try await user.delete(force: true, on: tx)
        }

        let suffix = DeletedDataPurgeJob.directoryName(tenantID: tenantID, deletedAt: now)
        softRename(vaultPaths.tenantRoot(for: tenantID), siblingName: suffix)
        // Profiles live under `<hermesDataRoot>/profiles/` (`HermesDataPathService`).
        // This used to rename `<hermesDataRoot>/<id>`, which never exists, so
        // Hermes data survived every deletion. The id is checked to be a plain
        // name before it is joined onto a path.
        if let hpid = hermesProfileID, DeletedDataPurgeJob.isSafeProfileName(hpid) {
            let hermesDir = HermesDataPathService(hermesDataRoot: hermesDataRoot).profileDirectory(for: hpid)
            softRename(hermesDir, siblingName: suffix)
        }

        // PII-safe audit. Sole identifier is tenantID; downstream log shippers
        // can correlate to deletion events without exposing the user payload.
        logger.info("account.deleted", metadata: ["tenantID": .string(tenantID.uuidString)])
    }

    private func verifyReAuth(
        user: User,
        password: String?,
        tokenIssuedAt: Date?,
        now: Date
    ) async throws {
        if let password, !password.isEmpty {
            guard await hasher.verify(password, hash: user.passwordHash) else {
                throw HTTPError(.unauthorized, message: "password incorrect")
            }
            return
        }
        if let iat = tokenIssuedAt, now.timeIntervalSince(iat) <= freshAuthWindow,
           now.timeIntervalSince(iat) >= 0
        {
            return
        }
        throw HTTPError(.unauthorized, message: "account deletion requires password or a JWT issued within \(Int(freshAuthWindow)) seconds")
    }

    private func softRename(_ url: URL, siblingName: String) {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return }
        let target = url.deletingLastPathComponent().appendingPathComponent(siblingName)
        do {
            try fm.moveItem(at: url, to: target)
        } catch {
            // Best-effort. The DB rows are already gone and we do not fail the
            // request on a filesystem hiccup — but the directory is left in
            // place under its live name, which the purge job never touches.
            // This error is the only signal; it needs an operator.
            logger.error(
                "account.deletion.rename_failed",
                metadata: ["path": .string(url.path), "error": .string("\(error)")]
            )
        }
    }
}
