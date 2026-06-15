@testable import App
import FluentKit
import FluentPostgresDriver
import Foundation
import HummingbirdFluent
import Logging
import LuminaVaultShared
import Testing

/// Direct-Fluent coverage for the Projects backend: M64 migration applies,
/// Project round-trips through Postgres + `toDTO`, and queries are
/// tenant-scoped (one tenant never sees another's projects).
@Suite(.serialized, .tags(.integration), .integrationDatabase, .disabled(if: IntegrationTestEnv.skipIntegration))
struct ProjectModelTests {
    private static func withFluent<T: Sendable>(
        _ body: @Sendable (Fluent) async throws -> T
    ) async throws -> T {
        let fluent = try await makeFluent()
        do {
            let result = try await body(fluent)
            try await fluent.shutdown()
            return result
        } catch {
            try? await fluent.shutdown()
            throw error
        }
    }

    private static func makeFluent() async throws -> Fluent {
        let fluent = Fluent(logger: Logger(label: "test.projects"))
        fluent.databases.use(.postgres(configuration: TestPostgres.configuration()), as: .psql)
        await fluent.migrations.add(M00_EnableExtensions())
        await fluent.migrations.add(M01_CreateUser())
        await fluent.migrations.add(M64_CreateProject())
        do {
            try await fluent.migrate()
            return fluent
        } catch {
            try? await fluent.shutdown()
            throw error
        }
    }

    private static func makeUser(_ slug: String, on db: any Database) async throws -> User {
        let user = User(email: "\(slug)@test.luminavault", username: slug, passwordHash: "stub-\(slug)")
        try await user.save(on: db)
        return user
    }

    @Test
    func `project round-trips and maps to DTO`() async throws {
        try await Self.withFluent { fluent in
            let slug = "proj1\(UUID().uuidString.prefix(6).lowercased())"
            let user = try await Self.makeUser(slug, on: fluent.db())
            let tenantID = try user.requireID()

            let project = Project(tenantID: tenantID, name: "Launch", description: "Q3 goals")
            try await project.save(on: fluent.db())

            let reloaded = try await Project.query(on: fluent.db(), tenantID: tenantID).first()
            #expect(reloaded != nil)
            let dto = try #require(reloaded).toDTO(todoCount: 0)
            #expect(dto.name == "Launch")
            #expect(dto.description == "Q3 goals")
            #expect(dto.archived == false)
            #expect(dto.todoCount == 0)
        }
    }

    @Test
    func `projects are tenant-scoped`() async throws {
        try await Self.withFluent { fluent in
            let a = try await Self.makeUser("pa\(UUID().uuidString.prefix(6).lowercased())", on: fluent.db())
            let b = try await Self.makeUser("pb\(UUID().uuidString.prefix(6).lowercased())", on: fluent.db())
            let aID = try a.requireID()
            let bID = try b.requireID()

            try await Project(tenantID: aID, name: "A-only").save(on: fluent.db())

            let bProjects = try await Project.query(on: fluent.db(), tenantID: bID).all()
            #expect(bProjects.isEmpty)
            let aProjects = try await Project.query(on: fluent.db(), tenantID: aID).all()
            #expect(aProjects.count == 1)
        }
    }
}
