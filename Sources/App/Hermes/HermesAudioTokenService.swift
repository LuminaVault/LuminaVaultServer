import FluentKit
import Foundation
import HummingbirdFluent
import JWTKit

/// Mints and revokes the scoped credential a tenant's Hermes container uses to
/// reach `/v1/audio/*`.
///
/// The token is an ordinary `SessionToken` carrying `scp = "audio"`, which
/// `JWTAuthenticator` refuses and `AudioJWTAuthenticator` accepts. It is
/// long-lived by necessity — nothing inside the container can perform an
/// interactive refresh — so the blast radius is bounded three ways instead:
/// the scope, a fixed expiry, and a per-tenant revocation epoch.
///
/// Rotation is expected on every gateway apply. The container is torn down and
/// recreated there anyway, so issuing a fresh token costs nothing and caps how
/// long an exfiltrated one stays useful.
struct HermesAudioTokenService: Sendable {
    let jwtKeys: JWTKeyCollection
    let jwtKID: JWKIdentifier
    let fluent: Fluent

    /// Long enough that a container left alone keeps working, short enough
    /// that an unrotated credential does not live indefinitely.
    static let lifetime: TimeInterval = 90 * 24 * 60 * 60

    /// Issues a scoped audio token for `tenantID`.
    func mint(tenantID: UUID, now: Date = Date()) async throws -> String {
        let token = SessionToken(
            userID: tenantID,
            expiration: now.addingTimeInterval(Self.lifetime),
            issuedAt: now,
            scp: SessionToken.Scope.audio
        )
        return try await jwtKeys.sign(token, kid: jwtKID)
    }

    /// Invalidates every outstanding audio token for `tenantID` and returns a
    /// fresh one.
    ///
    /// The epoch is written before the new token is minted so the two cannot
    /// race into a state where the just-issued credential is already stale;
    /// `mint` stamps `iat` after the write, and the authenticator requires
    /// `iat > epoch` strictly.
    func rotate(tenantID: UUID, now: Date = Date()) async throws -> String {
        try await revoke(tenantID: tenantID, now: now)
        return try await mint(tenantID: tenantID, now: now.addingTimeInterval(1))
    }

    /// Moves the revocation clock forward without issuing a replacement.
    func revoke(tenantID: UUID, now: Date = Date()) async throws {
        guard let user = try await User.find(tenantID, on: fluent.db()) else { return }
        user.hermesAudioTokenEpoch = now
        try await user.save(on: fluent.db())
    }
}
