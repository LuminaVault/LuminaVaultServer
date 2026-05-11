@testable import App
import Foundation
import Testing

/// HER-197 scaffold smoke tests. Documents the `SecretBox` contract:
/// `init(masterKeyBase64:)` rejects a missing or malformed master key;
/// `seal` / `open` round-trip when the master key is valid; the same
/// plaintext produces different ciphertexts for different tenants.
/// Currently the implementation throws on every entry point — that's
/// the asserted behavior so the test stays green until HER-197 main
/// commit implements crypto, at which point the assertions flip.
struct SecretBoxTests {
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

    // HER-197 follow-up — flip these to real round-trip assertions
    // once the AES-GCM + HKDF impl lands.
    //
    //   func `seal then open returns plaintext`() throws {
    //       let box = try SecretBox(masterKeyBase64: validKeyB64)
    //       let tenant = UUID()
    //       let sealed = try box.seal("Bearer abc", tenantID: tenant)
    //       #expect(try box.open(sealed, tenantID: tenant) == "Bearer abc")
    //   }
    //
    //   func `different tenants produce different ciphertexts`() throws {
    //       let box = try SecretBox(masterKeyBase64: validKeyB64)
    //       let a = try box.seal("same", tenantID: UUID())
    //       let b = try box.seal("same", tenantID: UUID())
    //       #expect(a.ciphertext != b.ciphertext)
    //   }
}
