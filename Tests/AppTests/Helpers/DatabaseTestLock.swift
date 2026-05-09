import Foundation

/// Serializes DB-using tests so migrations and seed data don't race.
@globalActor
actor DatabaseTestLock {
    static let shared = DatabaseTestLock()
}
