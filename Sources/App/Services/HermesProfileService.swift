import FluentKit
import Foundation
import HummingbirdFluent
import Logging

/// Talks to the Hermes container. Each user has exactly ONE Hermes Profile;
/// memory and state are fully isolated (Hermes-side guarantee). The username
/// IS the profile name — there is no separate slug column.
protocol HermesGateway: Sendable {
    func provisionProfile(tenantID: UUID, username: String) async throws -> String
    func deleteProfile(hermesProfileID: String) async throws
}

/// Dev/local fallback. Logs the call and returns a stable, human-readable
/// identifier so dev DB rows stay readable. No real provisioning happens.
struct LoggingHermesGateway: HermesGateway {
    let logger: Logger

    func provisionProfile(tenantID: UUID, username: String) async throws -> String {
        logger.warning("hermes (dev only): provisionProfile tenantID=\(tenantID) username=\(username)")
        return "hermes-\(username)"
    }

    func deleteProfile(hermesProfileID: String) async throws {
        logger.warning("hermes (dev only): deleteProfile id=\(hermesProfileID)")
    }
}

struct HermesProfileService {
    let fluent: Fluent
    let gateway: any HermesGateway
    let vaultPaths: VaultPathService

    /// Idempotent two-phase provisioning. Called from register, OAuth-create,
    /// any first-touch flow, and the scheduled reconciler.
    ///
    /// 1. If a `ready` row already exists, return it.
    /// 2. Otherwise insert (or reuse) a placeholder row with
    ///    `status = "provisioning"` and a sentinel `pending-<uuid>`
    ///    `hermes_profile_id` BEFORE calling the gateway. This keeps the
    ///    DB inspectable if the gateway hangs or the process dies mid-call,
    ///    and the scheduled reconciler can heal the row on its next pass.
    /// 3. Call the gateway. On success, flip the row to `ready` with the
    ///    real `hermes_profile_id`. On failure, flip to `error`, record
    ///    `last_error`, and rethrow — the caller decides whether the user-
    ///    facing operation fails or degrades.
    ///
    /// Both supported gateways (`Logging`, `Filesystem`) are idempotent.
    /// `pending-<uuid>` is naturally unique (the `unique(on:"hermes_profile_id")`
    /// constraint never collides between users).
    @discardableResult
    func ensure(for user: User) async throws -> HermesProfile {
        let tenantID = try user.requireID()
        if let existing = try await find(tenantID: tenantID), existing.status == "ready" {
            return existing
        }

        let row = try await reserveProvisioningRow(tenantID: tenantID)

        do {
            try vaultPaths.ensureTenantDirectories(for: tenantID)
            let hid = try await gateway.provisionProfile(tenantID: tenantID, username: user.username)
            row.hermesProfileID = hid
            row.status = "ready"
            row.lastError = nil
            try await row.save(on: fluent.db())
            return row
        } catch {
            row.status = "error"
            row.lastError = String(describing: error)
            try? await row.save(on: fluent.db())
            throw error
        }
    }

    /// Non-throwing variant: used by signup paths so a degraded Hermes
    /// gateway does not roll back the freshly-created `User`. The row is
    /// left in `provisioning` or `error`; the daily reconciler heals it.
    func ensureSoft(for user: User, logger: Logger) async {
        do {
            try await ensure(for: user)
        } catch {
            logger.warning("hermes profile provisioning degraded for \(user.username): \(error)")
        }
    }

    func find(for user: User) async throws -> HermesProfile? {
        try await find(tenantID: user.requireID())
    }

    private func find(tenantID: UUID) async throws -> HermesProfile? {
        try await HermesProfile.query(on: fluent.db(), tenantID: tenantID).first()
    }

    private func reserveProvisioningRow(tenantID: UUID) async throws -> HermesProfile {
        if let existing = try await find(tenantID: tenantID) {
            existing.status = "provisioning"
            existing.lastError = nil
            try await existing.save(on: fluent.db())
            return existing
        }
        let row = HermesProfile(
            tenantID: tenantID,
            hermesProfileID: "pending-\(tenantID.uuidString)",
            status: "provisioning",
        )
        try await row.save(on: fluent.db())
        return row
    }
}
