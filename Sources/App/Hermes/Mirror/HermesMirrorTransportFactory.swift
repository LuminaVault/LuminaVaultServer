import Foundation
import Logging
import LuminaVaultShared

/// Seam between `HermesMirrorService` and the concrete transport selection so
/// tests can pin a `FakeHermesMirrorTransport`.
protocol HermesMirrorTransportProviding: Sendable {
    func kind(tenantID: UUID) async -> HermesMirrorTransportKind
    func transport(tenantID: UUID) async throws -> any HermesMirrorTransport
}

/// Picks the mirror transport for a tenant:
/// - dashboard credentials on `user_hermes_config` → `RemoteHermesTransport`
///   (BYO; gateway resolution feeds the read-only skills fallback);
/// - otherwise `FilesystemHermesTransport` on the per-tenant container volume
///   when one exists, else the managed Hermes home on the shared PVC, with
///   sessions over the tenant's gateway resolution.
struct HermesMirrorTransportFactory: HermesMirrorTransportProviding {
    let credentials: HermesDashboardCredentialStore
    let ssrfGuard: SSRFGuard
    let resolver: HermesEndpointResolver
    let skillsClient: any HermesSkillsClienting
    let http: any HermesHTTPExecuting
    let containerManager: HermesContainerManager?
    let perTenantDataRootBase: String
    let managedHermesRoot: String
    let logger: Logger

    /// Cheap classification (one row read, no network).
    func kind(tenantID: UUID) async -> HermesMirrorTransportKind {
        if await (try? credentials.credentials(tenantID: tenantID)) != nil {
            return .remote
        }
        return .managed
    }

    func transport(tenantID: UUID) async throws -> any HermesMirrorTransport {
        if let dashboard = try await credentials.credentials(tenantID: tenantID) {
            let resolution = try? await resolver.resolve(tenantID: tenantID)
            return RemoteHermesTransport(
                gatewayBaseURL: resolution?.isUserOverride == true ? resolution?.baseURL : nil,
                gatewayAuthHeader: resolution?.authHeader,
                skillsClient: skillsClient,
                dashboard: HermesDashboardClient(
                    baseURL: dashboard.url,
                    token: dashboard.token,
                    ssrfGuard: ssrfGuard,
                    http: http,
                    logger: logger
                ),
                logger: logger
            )
        }
        return await managedTransport(tenantID: tenantID)
    }

    private func managedTransport(tenantID: UUID) async -> FilesystemHermesTransport {
        var root = managedHermesRoot
        var sessions: HermesGatewaySessionsClient?
        if let containerManager, let handle = try? await containerManager.handle(tenantID: tenantID) {
            let volume = "\(perTenantDataRootBase)/\(tenantID.uuidString.lowercased())"
            if FileManager.default.fileExists(atPath: volume) {
                root = volume
            }
            if let baseURL = URL(string: handle.baseURL) {
                sessions = HermesGatewaySessionsClient(
                    baseURL: baseURL,
                    authHeader: "Bearer \(handle.apiServerKey)",
                    http: http,
                    logger: logger
                )
            }
        }
        if sessions == nil, let resolution = try? await resolver.resolve(tenantID: tenantID) {
            sessions = HermesGatewaySessionsClient(
                baseURL: resolution.baseURL,
                authHeader: resolution.authHeader,
                http: http,
                logger: logger
            )
        }
        return FilesystemHermesTransport(rootPath: root, sessions: sessions, logger: logger)
    }
}
