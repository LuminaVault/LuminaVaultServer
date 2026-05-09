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

struct HermesProfileService: Sendable {
    let fluent: Fluent
    let gateway: any HermesGateway
    let vaultPaths: VaultPathService

    /// Idempotent. Called from register, OAuth-create, and any first-touch flow.
    @discardableResult
    func ensure(for user: User) async throws -> HermesProfile {
        let tenantID = try user.requireID()
        if let existing = try await find(tenantID: tenantID) {
            return existing
        }
        try vaultPaths.ensureTenantDirectories(for: tenantID)

        let profile = HermesProfile(tenantID: tenantID, hermesProfileID: "", status: "provisioning")
        try await profile.save(on: fluent.db())
        do {
            let hid = try await gateway.provisionProfile(tenantID: tenantID, username: user.username)
            profile.hermesProfileID = hid
            profile.status = "ready"
            try await profile.save(on: fluent.db())
        } catch {
            profile.status = "error"
            profile.lastError = String(describing: error)
            try? await profile.save(on: fluent.db())
            throw error
        }
        return profile
    }

    func find(for user: User) async throws -> HermesProfile? {
        try await find(tenantID: try user.requireID())
    }

    private func find(tenantID: UUID) async throws -> HermesProfile? {
        try await HermesProfile.query(on: fluent.db(), tenantID: tenantID).first()
    }
}
