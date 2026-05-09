import Testing

@testable import App

@Suite struct PasswordHasherTests {
    @Test func hashAndVerifyRoundTrip() async {
        let hasher = BcryptPasswordHasher(cost: 4)
        let hash = await hasher.hash("hunter2hunter2")
        #expect(await hasher.verify("hunter2hunter2", hash: hash) == true)
        #expect(await hasher.verify("wrongpassword", hash: hash) == false)
    }

    @Test func differentInputsProduceDifferentHashes() async {
        let hasher = BcryptPasswordHasher(cost: 4)
        let h1 = await hasher.hash("password1")
        let h2 = await hasher.hash("password2")
        #expect(h1 != h2)
    }
}
