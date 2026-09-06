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
/// - **a BYO gateway or dashboard credentials → `RemoteHermesTransport`**;
/// - otherwise `FilesystemHermesTransport` on the per-tenant container volume
///   when one exists, else the managed Hermes home on the shared PVC, with
///   sessions over the tenant's gateway resolution.
///
/// The gateway alone used to be insufficient: this keyed on dashboard
/// credentials, so a tenant who had linked only their gateway — which is all
/// the iOS app can store — silently fell through to the managed filesystem
/// transport rooted on *our* disk. It found an empty `skills/` and no
/// `cron/jobs.json` and reported `lastStatus: .ok` with zero counts and no
/// error: connected, importing nothing, complaining about nothing.
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

    /// Cheap classification (one row read plus the resolver, no network).
    func kind(tenantID: UUID) async -> HermesMirrorTransportKind {
        if await (try? credentials.credentials(tenantID: tenantID)) != nil {
            return .remote
        }
        if await (try? resolver.resolve(tenantID: tenantID))?.isUserOverride == true {
            return .remote
        }
        return .managed
    }

    func transport(tenantID: UUID) async throws -> any HermesMirrorTransport {
        let dashboard = try await credentials.credentials(tenantID: tenantID)
        let resolution = try? await resolver.resolve(tenantID: tenantID)
        let ownGateway = resolution?.isUserOverride == true ? resolution : nil

        // Either half is enough to talk to the user's own box.
        guard dashboard != nil || ownGateway != nil else {
            return await managedTransport(tenantID: tenantID)
        }

        return RemoteHermesTransport(
            gatewayBaseURL: ownGateway?.baseURL,
            gatewayAuthHeader: ownGateway?.authHeader,
            skillsClient: skillsClient,
            gateway: ownGateway.map {
                HermesGatewayReadClient(
                    baseURL: $0.baseURL,
                    authHeader: $0.authHeader,
                    http: http,
                    logger: logger
                )
            },
            dashboard: dashboard.map {
                HermesDashboardClient(
                    baseURL: $0.url,
                    token: $0.token,
                    ssrfGuard: ssrfGuard,
                    http: http,
                    logger: logger
                )
            },
            logger: logger
        )
    }

    private func managedTransport(tenantID: UUID) async -> FilesystemHermesTransport {
        var root = managedHermesRoot
        var sessions: HermesGatewayReadClient?
        if let containerManager, let handle = try? await containerManager.handle(tenantID: tenantID) {
            let volume = "\(perTenantDataRootBase)/\(tenantID.uuidString.lowercased())"
            if FileManager.default.fileExists(atPath: volume) {
                root = volume
            }
            if let baseURL = URL(string: handle.baseURL) {
                sessions = HermesGatewayReadClient(
                    baseURL: baseURL,
                    authHeader: "Bearer \(handle.apiServerKey)",
                    http: http,
                    logger: logger
                )
            }
        }
        if sessions == nil, let resolution = try? await resolver.resolve(tenantID: tenantID) {
            sessions = HermesGatewayReadClient(
                baseURL: resolution.baseURL,
                authHeader: resolution.authHeader,
                http: http,
                logger: logger
            )
        }
        return FilesystemHermesTransport(rootPath: root, sessions: sessions, logger: logger)
    }
}
