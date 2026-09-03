import FluentKit
import Foundation
import HummingbirdFluent

/// Reads the tenant's sealed dashboard URL + token from `user_hermes_config`
/// (the `cron_dashboard_*` columns — presented to clients as the "dashboard
/// token"). One reader for the capabilities probe, the mirror transport
/// factory and the refresh worker.
struct HermesDashboardCredentialStore: Sendable {
    struct Credentials: Sendable {
        let url: String
        let token: String
    }

    let fluent: Fluent
    let secretBox: SecretBox

    func credentials(tenantID: UUID) async throws -> Credentials? {
        guard let row = try await UserHermesConfig.query(on: fluent.db(), tenantID: tenantID).first() else {
            return nil
        }
        return try credentials(from: row, tenantID: tenantID)
    }

    func credentials(from row: UserHermesConfig, tenantID: UUID) throws -> Credentials? {
        guard let url = row.cronDashboardURL, !url.isEmpty,
              let ciphertext = row.cronDashboardTokenCiphertext,
              let nonce = row.cronDashboardTokenNonce
        else { return nil }
        let token = try secretBox.open(.init(ciphertext: ciphertext, nonce: nonce), tenantID: tenantID)
        return Credentials(url: url, token: token)
    }
}
