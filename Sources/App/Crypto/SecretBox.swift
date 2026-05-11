import Crypto
import Foundation

/// HER-197 scaffold — at-rest secret encryption helper.
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
/// See `SecretBoxBootCheck` (HER-197 follow-up) for the boot guard.
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

    /// 32 random bytes loaded from `LV_SECRET_MASTER_KEY` (base64).
    /// Held as `SymmetricKey` so a heap dump doesn't reveal raw bytes
    /// via String backing.
    private let masterKey: SymmetricKey

    /// Boot-time loader. Throws `Error.masterKeyMissing` if the env var
    /// is empty, `Error.masterKeyMalformed` if the base64 decodes to
    /// anything other than exactly 32 bytes.
    init(masterKeyBase64 _: String) throws {
        // HER-197 — implementation in follow-up commit. Scaffold rejects
        // every input so callers wire the failure path correctly first.
        throw Error.masterKeyMissing
    }

    /// Encrypt `plaintext` for `tenantID`. Returns `(ciphertext, nonce)`
    /// suitable for two `BYTEA` columns.
    ///
    /// Derives the per-tenant key via HKDF-SHA256(salt = `tenantID.uuidString.utf8`,
    /// info = `"lv.secretbox.v1"`). Nonce is a fresh 12-byte random per
    /// call (AES-GCM requirement: never reuse `(key, nonce)`).
    func seal(_: String, tenantID _: UUID) throws -> Sealed {
        throw Error.masterKeyMissing
    }

    /// Decrypt `sealed` for `tenantID`. Throws `Error.decryptionFailed`
    /// on authentication tag mismatch — caller treats that as
    /// "tampered or wrong tenant", not "soft-decode".
    func open(_: Sealed, tenantID _: UUID) throws -> String {
        throw Error.masterKeyMissing
    }
}
