import Testing

@testable import App

@Suite
struct UsernamePolicyTests {
    @Test
    func validatesGoodSlug() throws {
        #expect(try UsernamePolicy.validate("alice") == "alice")
        #expect(try UsernamePolicy.validate("john-doe") == "john-doe")
        #expect(try UsernamePolicy.validate("a1b2c3") == "a1b2c3")
        #expect(try UsernamePolicy.validate("  Alice  ") == "alice")
    }

    @Test
    func rejectsTooShort() {
        #expect(throws: (any Error).self) { try UsernamePolicy.validate("ab") }
    }

    @Test
    func rejectsTooLong() {
        #expect(throws: (any Error).self) {
            try UsernamePolicy.validate(String(repeating: "a", count: 32))
        }
    }

    @Test
    func rejectsInvalidChars() {
        #expect(throws: (any Error).self) { try UsernamePolicy.validate("with space") }
        #expect(throws: (any Error).self) { try UsernamePolicy.validate("under_score") }
        #expect(throws: (any Error).self) { try UsernamePolicy.validate("dot.dot") }
        #expect(throws: (any Error).self) { try UsernamePolicy.validate("-leading") }
    }

    @Test
    func rejectsReserved() {
        for word in ["admin", "root", "hermes", "system", "support", "api", "www", "luminavault"] {
            #expect(throws: (any Error).self) { try UsernamePolicy.validate(word) }
        }
    }

    @Test
    func placeholderMatchesPattern() throws {
        let placeholder = UsernamePolicy.placeholder()
        #expect(try UsernamePolicy.validate(placeholder) == placeholder)
        #expect(placeholder.hasPrefix("oauth-"))
    }
}
