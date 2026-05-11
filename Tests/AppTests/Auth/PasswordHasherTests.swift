@testable import App
import Testing

struct PasswordHasherTests {
    @Test func `hash and verify round trip`() async {
        let hasher = BcryptPasswordHasher(cost: 4)
        let hash = await hasher.hash("hunter2hunter2")
        #expect(await hasher.verify("hunter2hunter2", hash: hash) == true)
        #expect(await hasher.verify("wrongpassword", hash: hash) == false)
    }

    @Test func `different inputs produce different hashes`() async {
        let hasher = BcryptPasswordHasher(cost: 4)
        let h1 = await hasher.hash("password1")
        let h2 = await hasher.hash("password2")
        #expect(h1 != h2)
    }
}
