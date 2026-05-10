import FluentKit
import Foundation

/// A registered WebAuthn / passkey credential bound to a single user.
/// `credentialID` is the public, unique identifier the authenticator
/// presents at sign-in time. `publicKey` is the COSE-encoded blob.
final class WebAuthnCredential: Model, TenantModel, @unchecked Sendable {
    static let schema = "webauthn_credentials"

    @ID(key: .id) var id: UUID?
    @Field(key: "tenant_id") var tenantID: UUID
    @Field(key: "credential_id") var credentialID: String
    @Field(key: "public_key") var publicKey: Data
    @Field(key: "sign_count") var signCount: Int64
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}

    init(tenantID: UUID, credentialID: String, publicKey: Data, signCount: UInt32) {
        self.tenantID = tenantID
        self.credentialID = credentialID
        self.publicKey = publicKey
        self.signCount = Int64(signCount)
    }
}
