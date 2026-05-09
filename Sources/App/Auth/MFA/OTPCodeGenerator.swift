import Foundation

protocol OTPCodeGenerator: Sendable {
    func generate() -> String
}

struct DefaultOTPCodeGenerator: OTPCodeGenerator {
    func generate() -> String {
        String(format: "%06d", Int.random(in: 0..<1_000_000))
    }
}
