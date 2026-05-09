import Foundation
import Hummingbird

struct RegisterRequest: Codable, Sendable {
    let email: String
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
}

struct MeResponse: Codable, ResponseEncodable, Sendable {
    let userId: UUID
    let email: String
    let isVerified: Bool
}
