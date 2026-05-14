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

    /// Idempotent. Called from register, OAuth-create, and any first-touch flow.
    ///
    /// Gateway is called BEFORE the row is inserted so a failure leaves no
    /// half-state row behind. Both supported gateways (`Logging`, `Filesystem`)
    /// are idempotent, so a retry after a crash between gateway success and
    /// DB insert is safe.
    @discardableResult
    func ensure(for user: User) async throws -> HermesProfile {
        let tenantID = try user.requireID()
        if let existing = try await find(tenantID: tenantID) {
            return existing
        }
        try vaultPaths.ensureTenantDirectories(for: tenantID)

        let hid = try await gateway.provisionProfile(tenantID: tenantID, username: user.username)
        let profile = HermesProfile(tenantID: tenantID, hermesProfileID: hid, status: "ready")
        try await profile.save(on: fluent.db())
        return profile
    }

    func find(for user: User) async throws -> HermesProfile? {
        try await find(tenantID: user.requireID())
    }

    private func find(tenantID: UUID) async throws -> HermesProfile? {
        try await HermesProfile.query(on: fluent.db(), tenantID: tenantID).first()
    }
}
