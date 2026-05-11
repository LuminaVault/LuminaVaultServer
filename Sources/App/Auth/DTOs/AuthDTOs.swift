import Foundation
import Hummingbird

struct RegisterRequest: Codable {
    let email: String
    let username: String
    let password: String
}

struct LoginRequest: Codable {
    let email: String
    let password: String
    let mfaCode: String?
}

struct RefreshRequest: Codable {
    let refreshToken: String
}

struct AuthResponse: Codable, ResponseEncodable {
    let userId: UUID
    let email: String
    let accessToken: String
    let refreshToken: String
    let expiresIn: Int
    let mfaRequired: Bool?
    let mfaChallengeId: UUID?
}

struct MFAVerifyRequest: Codable {
    let challengeId: UUID
    let code: String
}

struct MFAResendRequest: Codable {
    let email: String
}

struct OAuthExchangeRequest: Codable {
    let idToken: String
}

struct ForgotPasswordRequest: Codable {
    let email: String
}

struct ResetPasswordRequest: Codable {
    let email: String
    let code: String
    let newPassword: String
}

struct SendVerificationRequest: Codable {
    let email: String
}

struct ConfirmEmailRequest: Codable {
    let email: String
    let code: String
}

struct MeResponse: Codable, ResponseEncodable {
    let userId: UUID
    let email: String
    let username: String
    let isVerified: Bool
}
