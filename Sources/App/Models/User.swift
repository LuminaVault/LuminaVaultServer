import FluentKit
import Foundation

final class User: Model, @unchecked Sendable {
    static let schema = "users"

    @ID(key: .id) var id: UUID?
    @Field(key: "email") var email: String
    @Field(key: "password_hash") var passwordHash: String
    @Field(key: "is_verified") var isVerified: Bool
    @Field(key: "failed_login_attempts") var failedLoginAttempts: Int
    @OptionalField(key: "lockout_until") var lockoutUntil: Date?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        email: String,
        passwordHash: String,
        isVerified: Bool = false,
        failedLoginAttempts: Int = 0,
        lockoutUntil: Date? = nil
    ) {
        self.id = id
        self.email = email.lowercased()
        self.passwordHash = passwordHash
        self.isVerified = isVerified
        self.failedLoginAttempts = failedLoginAttempts
        self.lockoutUntil = lockoutUntil
    }
}
