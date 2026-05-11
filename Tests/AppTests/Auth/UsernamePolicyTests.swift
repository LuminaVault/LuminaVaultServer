@testable import App
import Testing

struct UsernamePolicyTests {
    @Test
    func `validates good slug`() throws {
        #expect(try UsernamePolicy.validate("alice") == "alice")
        #expect(try UsernamePolicy.validate("john-doe") == "john-doe")
        #expect(try UsernamePolicy.validate("a1b2c3") == "a1b2c3")
        #expect(try UsernamePolicy.validate("  Alice  ") == "alice")
    }

    @Test
    func `rejects too short`() {
        #expect(throws: (any Error).self) { try UsernamePolicy.validate("ab") }
    }

    @Test
    func `rejects too long`() {
        #expect(throws: (any Error).self) {
            try UsernamePolicy.validate(String(repeating: "a", count: 32))
        }
    }

    @Test
    func `rejects invalid chars`() {
        #expect(throws: (any Error).self) { try UsernamePolicy.validate("with space") }
        #expect(throws: (any Error).self) { try UsernamePolicy.validate("under_score") }
        #expect(throws: (any Error).self) { try UsernamePolicy.validate("dot.dot") }
        #expect(throws: (any Error).self) { try UsernamePolicy.validate("-leading") }
    }

    @Test
    func `rejects reserved`() {
        for word in ["admin", "root", "hermes", "system", "support", "api", "www", "luminavault"] {
            #expect(throws: (any Error).self) { try UsernamePolicy.validate(word) }
        }
    }

    @Test
    func `placeholder matches pattern`() throws {
        let placeholder = UsernamePolicy.placeholder()
        #expect(try UsernamePolicy.validate(placeholder) == placeholder)
        #expect(placeholder.hasPrefix("oauth-"))
    }
}
