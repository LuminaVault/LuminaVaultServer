@testable import App
import FluentKit
import Foundation
import HummingbirdFluent
import Logging
import LuminaVaultShared
import Testing

/// What the mirror does when a BYO gateway is configured but unusable.
///
/// The gateway-only bug had a twin. `transport(tenantID:)` resolved the
/// tenant's endpoint with `try?`, so an SSRF rejection or a decrypt failure
/// came back as "no override" rather than as an error. A tenant with no
/// dashboard then fell through to the managed filesystem transport rooted on
/// *our* disk, found an empty `skills/` and no `cron/jobs.json`, and the sync
/// recorded `lastStatus: .ok` with zero counts and no error — connected,
/// importing nothing, complaining about nothing.
///
/// It is not a hypothetical shape. A stored URL is re-validated on every
/// resolve (DNS-rebinding defence), so a gateway that was public at save time
/// and is private-range now fails here, forever, silently. `sync` already
/// records a throw from `transport` as `lastStatus: .failed` carrying the
/// error text, which is what the settings screen renders — so the fix is to
/// stop swallowing it.
@Suite(.serialized, .tags(.integration), .integrationDatabase, .disabled(if: IntegrationTestEnv.skipIntegration))
struct MirrorTransportFallbackTests {
    private static let testMasterKeyBase64 = Data((0 ..< 32).map { UInt8($0) }).base64EncodedString()
    private static let managedURL = URL(string: "http://managed.hermes.test")!
    private static let logger = Logger(label: "lv.test.mirror.fallback")

    /// `evil.test` resolves into RFC1918, which is what the guard rejects once
    /// private ranges are closed — the same verdict production reaches for a
    /// ClusterIP or a LAN address.
    private static func withFactory<Result>(
        _ body: (HermesMirrorTransportFactory, Fluent, SecretBox) async throws -> Result
    ) async throws -> Result {
        try await withTestFluent(label: "lv.test.mirror.fallback") { fluent in
            let secretBox = try SecretBox(masterKeyBase64: testMasterKeyBase64)
            let ssrfGuard = SSRFGuard(
                allowPrivateRanges: false,
                requireHTTPS: false,
                resolver: SSRFGuardTests.StubResolver(
                    answers: [
                        "managed.hermes.test": ["93.184.216.34"],
                        "good.hermes.test": ["93.184.216.34"],
                        "dash.hermes.test": ["93.184.216.34"],
                        "evil.test": ["10.0.0.1"],
                    ]
                )
            )
            let resolver = HermesEndpointResolver(
                fluent: fluent,
                secretBox: secretBox,
                ssrfGuard: ssrfGuard,
                defaultBaseURL: managedURL,
                logger: logger
            )
            let http = StubHermesHTTP()
            let factory = HermesMirrorTransportFactory(
                credentials: HermesDashboardCredentialStore(fluent: fluent, secretBox: secretBox),
                ssrfGuard: ssrfGuard,
                resolver: resolver,
                skillsClient: HermesSkillsClient(http: http, logger: logger),
                http: http,
                containerManager: nil,
                perTenantDataRootBase: NSTemporaryDirectory() + "lv-test-tenants",
                managedHermesRoot: NSTemporaryDirectory() + "lv-test-managed-hermes",
                logger: logger
            )
            return try await body(factory, fluent, secretBox)
        }
    }

    /// M90: `tenant_id` references `vaults(id)`, so a test saving a `User`
    /// directly has to provision the vault registration would have made.
    private static func makeTenant(fluent: Fluent) async throws -> UUID {
        let user = User()
        user.email = "mirror-\(UUID().uuidString.prefix(8))@test.luminavault"
        user.username = "mirror-\(UUID().uuidString.prefix(8))"
        user.passwordHash = "x"
        user.tier = "trial"
        user.tierOverride = "none"
        try await user.save(on: fluent.db())
        try await DefaultAuthService.ensurePersonalVault(for: user, on: fluent.db())
        return try user.requireID()
    }

    @Test
    func `a gateway that no longer resolves is raised, not swapped for our own disk`() async throws {
        try await Self.withFactory { factory, fluent, _ in
            let tenantID = try await Self.makeTenant(fluent: fluent)
            let row = UserHermesConfig()
            row.tenantID = tenantID
            row.baseURL = "https://evil.test"
            try await row.save(on: fluent.db())

            await #expect(throws: HermesEndpointResolver.ResolutionError.self) {
                _ = try await factory.transport(tenantID: tenantID)
            }
        }
    }

    @Test
    func `that tenant is reported as none rather than as managed`() async throws {
        try await Self.withFactory { factory, fluent, _ in
            let tenantID = try await Self.makeTenant(fluent: fluent)
            let row = UserHermesConfig()
            row.tenantID = tenantID
            row.baseURL = "https://evil.test"
            try await row.save(on: fluent.db())

            // `.managed` here would name the shared PVC as the thing serving
            // them, which is exactly the reading that hid this for so long.
            #expect(await factory.kind(tenantID: tenantID) == HermesMirrorTransportKind.none)
        }
    }

    @Test
    func `a broken gateway does not take the dashboard down with it`() async throws {
        try await Self.withFactory { factory, fluent, secretBox in
            let tenantID = try await Self.makeTenant(fluent: fluent)
            let sealed = try secretBox.seal("dashboard-token", tenantID: tenantID)
            let row = UserHermesConfig()
            row.tenantID = tenantID
            row.baseURL = "https://evil.test"
            row.cronDashboardURL = "https://dash.hermes.test"
            row.cronDashboardTokenCiphertext = sealed.ciphertext
            row.cronDashboardTokenNonce = sealed.nonce
            try await row.save(on: fluent.db())

            // The dashboard is a second door into the same box. Refusing it
            // because the other door is stuck would be a regression, not a fix.
            let transport = try await factory.transport(tenantID: tenantID)
            #expect(transport.kind == .remote)
        }
    }

    @Test
    func `a tenant who configured nothing still gets the managed transport`() async throws {
        try await Self.withFactory { factory, fluent, _ in
            let tenantID = try await Self.makeTenant(fluent: fluent)

            // No row at all: the resolver returns the managed default without
            // throwing, so nothing here should have become louder.
            let transport = try await factory.transport(tenantID: tenantID)
            #expect(transport.kind == .managed)
            #expect(await factory.kind(tenantID: tenantID) == .managed)
        }
    }

    @Test
    func `a gateway that still resolves is untouched`() async throws {
        try await Self.withFactory { factory, fluent, _ in
            let tenantID = try await Self.makeTenant(fluent: fluent)
            let row = UserHermesConfig()
            row.tenantID = tenantID
            row.baseURL = "https://good.hermes.test"
            try await row.save(on: fluent.db())

            let transport = try await factory.transport(tenantID: tenantID)
            #expect(transport.kind == .remote)
            #expect(await factory.kind(tenantID: tenantID) == .remote)
        }
    }
}
