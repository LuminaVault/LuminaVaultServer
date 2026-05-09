import FluentKit
import Foundation
import HummingbirdFluent

protocol AuthRepository: Sendable {
    func createUser(email: String, username: String, passwordHash: String) async throws -> User
    func findUser(byEmail email: String) async throws -> User?
    func findUser(byUsername username: String) async throws -> User?
    func findUser(byID id: UUID) async throws -> User?
    func incrementFailedLogin(userID: UUID, lockoutAt: Date?) async throws
    func resetFailedLogin(userID: UUID) async throws
}

struct DatabaseAuthRepository: AuthRepository {
    let fluent: Fluent

    func createUser(email: String, username: String, passwordHash: String) async throws -> User {
        let user = User(email: email, username: username, passwordHash: passwordHash)
        try await user.save(on: fluent.db())
        return user
    }

    func findUser(byEmail email: String) async throws -> User? {
        try await User.query(on: fluent.db())
            .filter(\.$email == email.lowercased())
            .first()
    }

    func findUser(byUsername username: String) async throws -> User? {
        try await User.query(on: fluent.db())
            .filter(\.$username == username.lowercased())
            .first()
    }

    func findUser(byID id: UUID) async throws -> User? {
        try await User.find(id, on: fluent.db())
    }

    func incrementFailedLogin(userID: UUID, lockoutAt: Date?) async throws {
        guard let user = try await findUser(byID: userID) else { return }
        user.failedLoginAttempts += 1
        user.lockoutUntil = lockoutAt
        try await user.save(on: fluent.db())
    }

    func resetFailedLogin(userID: UUID) async throws {
        guard let user = try await findUser(byID: userID) else { return }
        user.failedLoginAttempts = 0
        user.lockoutUntil = nil
        try await user.save(on: fluent.db())
    }
}
