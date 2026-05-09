import Foundation
import Hummingbird

struct RegisterRequest: Codable, Sendable {
	let email: String
	let username: String
	let password: String
}

struct LoginRequest: Codable, Sendable {
	let email: String
	let password: String
	let mfaCode: String?
}

struct RefreshRequest: Codable, Sendable {
	let refreshToken: String
}

struct AuthResponse: Codable, ResponseEncodable, Sendable {
	let userId: UUID
	let email: String
	let accessToken: String
	let refreshToken: String
	let expiresIn: Int
	let mfaRequired: Bool?
	let mfaChallengeId: UUID?
}

struct MFAVerifyRequest: Codable, Sendable {
	let challengeId: UUID
	let code: String
}

struct MFAResendRequest: Codable, Sendable {
	let email: String
}

struct OAuthExchangeRequest: Codable, Sendable {
	let idToken: String
}

struct ForgotPasswordRequest: Codable, Sendable {
	let email: String
}

struct ResetPasswordRequest: Codable, Sendable {
	let email: String
	let code: String
	let newPassword: String
}

struct MeResponse: Codable, ResponseEncodable, Sendable {
	let userId: UUID
	let email: String
	let username: String
	let isVerified: Bool
}
