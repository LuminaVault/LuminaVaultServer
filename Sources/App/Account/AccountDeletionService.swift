import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import Logging

/// HER-92: GDPR / CCPA account-deletion service.
///
/// Flow:
///   1. Re-auth gate — caller must supply `password` (verified against the bcrypt hash)
///      OR present a JWT whose `iat` is within `freshAuthWindow` (default 5 minutes).
///      OAuth-only users with no remembered password use the fresh-JWT path: log in
///      again immediately before calling DELETE.
///   2. Drop the `users` row. Every child table has `ON DELETE CASCADE` on
///      `users(id)`, so refresh_tokens, memories, hermes_profile, mfa_challenges,
///      oauth_identities, vault_files, spaces, health_events, device_tokens,
///      webauthn_credentials, password_reset_tokens, email_verification_tokens,
///      and onboarding_state are wiped atomically.
///   3. Soft-delete on-disk artifacts — rename `<vaultRoot>/tenants/<id>` and
///      `<hermesDataRoot>/<hermesProfileID>` to `_deleted_<ts>_<id>` siblings.
///      Operator cron erases anything older than 30 days.
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
        now: Date = Date(),
    ) async throws {
        let tenantID = try user.requireID()

        try await verifyReAuth(
            user: user, password: password, tokenIssuedAt: tokenIssuedAt, now: now,
        )

        // Capture Hermes profile id BEFORE the cascade wipes the row.
        let hermesProfileID = try await HermesProfile
            .query(on: fluent.db(), tenantID: tenantID)
            .first()?
            .hermesProfileID

        // CASCADE drops every FK-owned row across 13 child tables.
        try await user.delete(force: true, on: fluent.db())

        let suffix = "_deleted_\(Int(now.timeIntervalSince1970))_\(tenantID.uuidString)"
        softRename(vaultPaths.tenantRoot(for: tenantID), siblingName: suffix)
        if let hpid = hermesProfileID, !hpid.isEmpty {
            let hermesDir = URL(fileURLWithPath: hermesDataRoot).appendingPathComponent(hpid)
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
        now: Date,
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
            // Best-effort. We do not block the DB delete on a filesystem hiccup;
            // the operator cron will catch orphan dirs separately.
            logger.error(
                "account.deletion.rename_failed",
                metadata: ["path": .string(url.path), "error": .string("\(error)")],
            )
        }
    }
}
