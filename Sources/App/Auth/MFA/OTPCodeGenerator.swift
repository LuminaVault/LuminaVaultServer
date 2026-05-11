import Foundation

protocol OTPCodeGenerator: Sendable {
    func generate() -> String
}

struct DefaultOTPCodeGenerator: OTPCodeGenerator {
    func generate() -> String {
        String(format: "%06d", Int.random(in: 0..<1_000_000))
    }
}

/// Deterministic generator. Always returns the same code. Intended for
/// integration tests that need to drive OTP-gated flows end-to-end without
/// scraping logs; wired in production only when `phone.fixedOtp` is set
/// (which itself is a security hole — never set in prod).
struct FixedOTPCodeGenerator: OTPCodeGenerator {
    let code: String
    func generate() -> String { code }
}
