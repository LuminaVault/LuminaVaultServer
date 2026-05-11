@testable import App
import Foundation
import Testing

struct PreAuthChallengeStoreTests {
    @Test func `issued code consumes once`() async {
        let store = PreAuthChallengeStore()
        let (id, expiresAt) = await store.issue(
            channel: "sms",
            destination: "+15551112222",
            purpose: "phone_signin",
            code: "123456",
        )
        #expect(!id.uuidString.isEmpty)
        #expect(expiresAt > Date())

        let result = await store.consume(destination: "+15551112222", code: "123456")
        #expect(result?.destination == "+15551112222")
        #expect(result?.purpose == "phone_signin")

        // Burn-on-success — second consume must fail.
        let again = await store.consume(destination: "+15551112222", code: "123456")
        #expect(again == nil)
    }

    @Test func `wrong code fails and counts`() async {
        let store = PreAuthChallengeStore()
        _ = await store.issue(channel: "sms", destination: "+15552223333", purpose: "phone_signin", code: "ok-code")

        // 5 wrong attempts → challenge burned
        for _ in 0 ..< 5 {
            let r = await store.consume(destination: "+15552223333", code: "wrong")
            #expect(r == nil)
        }
        // Even the right code now fails because challenge was burned.
        let r = await store.consume(destination: "+15552223333", code: "ok-code")
        #expect(r == nil)
    }

    @Test func `reissue burns prior challenge`() async {
        let store = PreAuthChallengeStore()
        _ = await store.issue(channel: "email", destination: "alice@x.io", purpose: "magic_link", code: "AAA")
        _ = await store.issue(channel: "email", destination: "alice@x.io", purpose: "magic_link", code: "BBB")
        // Old code rejected
        #expect(await store.consume(destination: "alice@x.io", code: "AAA") == nil)
        // New code works
        #expect(await store.consume(destination: "alice@x.io", code: "BBB") != nil)
    }

    @Test func `different destinations are independent`() async {
        let store = PreAuthChallengeStore()
        _ = await store.issue(channel: "sms", destination: "+1", purpose: "phone_signin", code: "AAA")
        _ = await store.issue(channel: "sms", destination: "+2", purpose: "phone_signin", code: "BBB")
        #expect(await store.consume(destination: "+1", code: "AAA") != nil)
        #expect(await store.consume(destination: "+2", code: "BBB") != nil)
    }

    // MARK: - HER-137 typed outcomes

    @Test func `consume typed returns ok on happy path`() async {
        let store = PreAuthChallengeStore()
        _ = await store.issue(channel: "sms", destination: "+15551234567", purpose: "phone_signin", code: "111111")
        switch await store.consumeTyped(destination: "+15551234567", code: "111111") {
        case let .ok(dest, purpose):
            #expect(dest == "+15551234567")
            #expect(purpose == "phone_signin")
        default:
            Issue.record("expected .ok")
        }
    }

    @Test func `consume typed returns expired`() async {
        // Negative lifetime → challenge is born already past `expiresAt`.
        let store = PreAuthChallengeStore(lifetime: -1)
        _ = await store.issue(channel: "sms", destination: "+15551234567", purpose: "phone_signin", code: "111111")
        switch await store.consumeTyped(destination: "+15551234567", code: "111111") {
        case .expired:
            break
        default:
            Issue.record("expected .expired")
        }
    }

    @Test func `consume typed returns wrong code then locked out`() async {
        let store = PreAuthChallengeStore()
        _ = await store.issue(channel: "sms", destination: "+15551234567", purpose: "phone_signin", code: "111111")
        // First 4 wrong attempts → .wrongCode each time.
        for _ in 0 ..< 4 {
            switch await store.consumeTyped(destination: "+15551234567", code: "wrong") {
            case .wrongCode: break
            default: Issue.record("expected .wrongCode")
            }
        }
        // 5th wrong attempt → .lockedOut and burns the entry.
        switch await store.consumeTyped(destination: "+15551234567", code: "wrong") {
        case .lockedOut: break
        default: Issue.record("expected .lockedOut")
        }
        // Right code now returns .notFound (entry was burned).
        switch await store.consumeTyped(destination: "+15551234567", code: "111111") {
        case .notFound: break
        default: Issue.record("expected .notFound after lockout")
        }
    }

    @Test func `consume typed returns not found for unknown destination`() async {
        let store = PreAuthChallengeStore()
        switch await store.consumeTyped(destination: "+15551234567", code: "111111") {
        case .notFound: break
        default: Issue.record("expected .notFound")
        }
    }
}

struct PhoneE164ValidatorTests {
    @Test func `accepts valid E 164`() throws {
        #expect(try PhoneAuthController.validateE164("+15551234567") == "+15551234567")
        #expect(try PhoneAuthController.validateE164("  +442071838750  ") == "+442071838750")
        #expect(try PhoneAuthController.validateE164("+5511987654321") == "+5511987654321")
    }

    @Test func `rejects invalid`() {
        #expect(throws: (any Error).self) { try PhoneAuthController.validateE164("5551234567") } // no +
        #expect(throws: (any Error).self) { try PhoneAuthController.validateE164("+0123456") } // leading 0
        #expect(throws: (any Error).self) { try PhoneAuthController.validateE164("+12") } // too short
        #expect(throws: (any Error).self) { try PhoneAuthController.validateE164("+1234567890123456") } // too long (>15 digits)
        #expect(throws: (any Error).self) { try PhoneAuthController.validateE164("+1-555-123-4567") } // dashes
        #expect(throws: (any Error).self) { try PhoneAuthController.validateE164("") }
    }
}
