@testable import App
import Foundation
import Testing

/// The `SecretBox` contract. Every BYO provider key, Hermes dashboard token
/// and gateway credential in the system is sealed through this.
///
/// These assertions were written as commented-out scaffolding in HER-197,
/// against an implementation that then threw on every entry point. The
/// AES-GCM + HKDF implementation landed and the tests were never switched on,
/// so the property that matters most here — a credential sealed for one
/// tenant must not open for another — had no coverage at all.
struct SecretBoxTests {
    /// 32 zero bytes. Fine for a test; the real key comes from
    /// `LV_SECRET_MASTER_KEY`.
    private static let validKeyB64 = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

    private static func box() throws -> SecretBox {
        try SecretBox(masterKeyBase64: validKeyB64)
    }

    @Test
    func `init rejects empty master key`() {
        #expect(throws: SecretBox.Error.self) {
            _ = try SecretBox(masterKeyBase64: "")
        }
    }

    @Test
    func `init rejects malformed base64`() {
        #expect(throws: SecretBox.Error.self) {
            _ = try SecretBox(masterKeyBase64: "not-base-64!!")
        }
    }

    /// AES-256 needs exactly 32 bytes; a short key must not be silently
    /// stretched.
    @Test
    func `init rejects a key of the wrong length`() {
        #expect(throws: SecretBox.Error.self) {
            _ = try SecretBox(masterKeyBase64: Data(repeating: 0, count: 16).base64EncodedString())
        }
    }

    // MARK: - Round trip

    @Test
    func `seal then open returns the plaintext`() throws {
        let box = try Self.box()
        let tenant = UUID()
        let sealed = try box.seal("sk-live-abc123", tenantID: tenant)
        #expect(try box.open(sealed, tenantID: tenant) == "sk-live-abc123")
    }

    @Test
    func `round trip survives unicode and empty strings`() throws {
        let box = try Self.box()
        let tenant = UUID()
        for plaintext in ["", "Bearer ünïcødé 🔑", String(repeating: "x", count: 8192)] {
            let sealed = try box.seal(plaintext, tenantID: tenant)
            #expect(try box.open(sealed, tenantID: tenant) == plaintext)
        }
    }

    /// Fresh nonce per call, so the same plaintext for the same tenant must
    /// not produce the same ciphertext — reusing a (key, nonce) pair under
    /// AES-GCM is catastrophic, not merely untidy.
    @Test
    func `the same plaintext never seals to the same bytes twice`() throws {
        let box = try Self.box()
        let tenant = UUID()
        let a = try box.seal("same", tenantID: tenant)
        let b = try box.seal("same", tenantID: tenant)
        #expect(a.ciphertext != b.ciphertext)
        #expect(a.nonce != b.nonce)
    }

    // MARK: - Tenant isolation

    /// The property the whole scheme exists for: a row copied out of one
    /// tenant's table and into another's is undecryptable, because the key is
    /// derived from the tenant id rather than merely filtered on it.
    @Test
    func `a credential sealed for one tenant does not open for another`() throws {
        let box = try Self.box()
        let owner = UUID()
        let attacker = UUID()
        let sealed = try box.seal("sk-live-secret", tenantID: owner)
        #expect(throws: SecretBox.Error.self) {
            _ = try box.open(sealed, tenantID: attacker)
        }
    }

    @Test
    func `different tenants produce different ciphertexts`() throws {
        let box = try Self.box()
        let a = try box.seal("same", tenantID: UUID())
        let b = try box.seal("same", tenantID: UUID())
        #expect(a.ciphertext != b.ciphertext)
    }

    // MARK: - Tampering

    /// The GCM tag must be checked, not just carried alongside.
    @Test
    func `a flipped ciphertext bit fails authentication`() throws {
        let box = try Self.box()
        let tenant = UUID()
        var sealed = try box.seal("sk-live-abc123", tenantID: tenant)
        var bytes = [UInt8](sealed.ciphertext)
        bytes[0] ^= 0x01
        sealed = SecretBox.Sealed(ciphertext: Data(bytes), nonce: sealed.nonce)
        #expect(throws: SecretBox.Error.self) {
            _ = try box.open(sealed, tenantID: tenant)
        }
    }

    @Test
    func `a swapped nonce fails authentication`() throws {
        let box = try Self.box()
        let tenant = UUID()
        let a = try box.seal("first", tenantID: tenant)
        let b = try box.seal("second", tenantID: tenant)
        let spliced = SecretBox.Sealed(ciphertext: a.ciphertext, nonce: b.nonce)
        #expect(throws: SecretBox.Error.self) {
            _ = try box.open(spliced, tenantID: tenant)
        }
    }

    /// Truncated to shorter than a GCM tag — must be rejected rather than
    /// indexed into.
    @Test
    func `a truncated ciphertext is rejected`() throws {
        let box = try Self.box()
        let tenant = UUID()
        let sealed = try box.seal("sk-live-abc123", tenantID: tenant)
        let truncated = SecretBox.Sealed(
            ciphertext: sealed.ciphertext.prefix(8),
            nonce: sealed.nonce
        )
        #expect(throws: SecretBox.Error.self) {
            _ = try box.open(truncated, tenantID: tenant)
        }
    }

    /// A different master key must not open another deployment's rows.
    @Test
    func `a different master key cannot open the ciphertext`() throws {
        let tenant = UUID()
        let sealed = try Self.box().seal("sk-live-abc123", tenantID: tenant)
        let otherKey = try SecretBox(
            masterKeyBase64: Data(repeating: 7, count: 32).base64EncodedString()
        )
        #expect(throws: SecretBox.Error.self) {
            _ = try otherKey.open(sealed, tenantID: tenant)
        }
    }
}
