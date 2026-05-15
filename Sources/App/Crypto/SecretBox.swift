import Crypto
import Foundation

/// HER-217 — at-rest secret encryption helper (HER-197 follow-up).
///
/// AES-GCM via `CryptoKit.AES.GCM`. The master key is read from
/// `LV_SECRET_MASTER_KEY` (base64-encoded 32 bytes) at boot. Per-tenant
/// keys are derived via HKDF-SHA256 with the tenant UUID's `utf8`
/// representation as the salt, so two tenants encrypting the same
/// plaintext produce different ciphertexts and a leaked master key
/// alone cannot decrypt without also knowing the tenant id.
///
/// First user: HER-197 `user_hermes_config.auth_header_*`. Second user:
/// BYO LLM Key (`user_provider_keys`) — same `SecretBox`, no second
/// crypto layer.
///
/// Boot contract: if `LV_SECRET_MASTER_KEY` is unset AND any BYO table
/// has rows, the app MUST refuse to boot. No silent plaintext fallback.
struct SecretBox {
    /// Sealed value: ciphertext + per-call nonce. Persisted as two
    /// separate `BYTEA` columns so the column types remain inspectable
    /// in pg admin tools.
    struct Sealed: Hashable {
        let ciphertext: Data
        let nonce: Data
    }

    enum Error: Swift.Error, Equatable {
        case masterKeyMissing
        case masterKeyMalformed
        case decryptionFailed
        case tenantSaltEmpty
    }

    private static let hkdfInfo = Data("lv.secretbox.v1".utf8)

    /// 32 random bytes loaded from `LV_SECRET_MASTER_KEY` (base64).
    /// Held as `SymmetricKey` so a heap dump doesn't reveal raw bytes
    /// via String backing.
    private let masterKey: SymmetricKey

    init(masterKeyBase64: String) throws {
        guard !masterKeyBase64.isEmpty else {
            throw Error.masterKeyMissing
        }
        guard let raw = Data(base64Encoded: masterKeyBase64) else {
            throw Error.masterKeyMalformed
        }
        guard raw.count == 32 else {
            throw Error.masterKeyMalformed
        }
        masterKey = SymmetricKey(data: raw)
    }

    /// Encrypt `plaintext` for `tenantID`. Returns `(ciphertext, nonce)`
    /// suitable for two `BYTEA` columns.
    ///
    /// Derives the per-tenant key via HKDF-SHA256(salt = `tenantID.uuidString.utf8`,
    /// info = `"lv.secretbox.v1"`). Nonce is a fresh 12-byte random per
    /// call (AES-GCM requirement: never reuse `(key, nonce)`).
    func seal(_ plaintext: String, tenantID: UUID) throws -> Sealed {
        let key = try perTenantKey(tenantID: tenantID)
        let nonce = AES.GCM.Nonce()
        let sealed = try AES.GCM.seal(Data(plaintext.utf8), using: key, nonce: nonce)
        return Sealed(
            ciphertext: sealed.ciphertext + sealed.tag,
            nonce: Data(nonce),
        )
    }

    /// Decrypt `sealed` for `tenantID`. Throws `Error.decryptionFailed`
    /// on authentication tag mismatch — caller treats that as
    /// "tampered or wrong tenant", not "soft-decode".
    func open(_ sealed: Sealed, tenantID: UUID) throws -> String {
        let key = try perTenantKey(tenantID: tenantID)
        guard sealed.ciphertext.count >= 16 else {
            throw Error.decryptionFailed
        }
        let tag = sealed.ciphertext.suffix(16)
        let ct = sealed.ciphertext.prefix(sealed.ciphertext.count - 16)
        let nonce: AES.GCM.Nonce
        do {
            nonce = try AES.GCM.Nonce(data: sealed.nonce)
        } catch {
            throw Error.decryptionFailed
        }
        let box: AES.GCM.SealedBox
        do {
            box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ct, tag: tag)
        } catch {
            throw Error.decryptionFailed
        }
        let plaintext: Data
        do {
            plaintext = try AES.GCM.open(box, using: key)
        } catch {
            throw Error.decryptionFailed
        }
        guard let utf8 = String(data: plaintext, encoding: .utf8) else {
            throw Error.decryptionFailed
        }
        return utf8
    }

    private func perTenantKey(tenantID: UUID) throws -> SymmetricKey {
        let salt = Data(tenantID.uuidString.utf8)
        guard !salt.isEmpty else {
            throw Error.tenantSaltEmpty
        }
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: masterKey,
            salt: salt,
            info: Self.hkdfInfo,
            outputByteCount: 32,
        )
    }
}
