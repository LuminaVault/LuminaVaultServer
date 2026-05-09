import FluentKit
import Foundation
import HummingbirdFluent

struct MemoryRepository: Sendable {
    let fluent: Fluent

    func create(content: String, context: AppRequestContext) async throws -> Memory {
        let tenantID = try context.requireTenantID()
        let m = Memory(tenantID: tenantID, content: content)
        try await m.save(on: fluent.db())
        return m
    }

    /// Lists memories owned by the authenticated tenant.
    /// Tenant filter is applied by `Memory.query(on:context:)`.
    func list(context: AppRequestContext) async throws -> [Memory] {
        try await Memory.query(on: fluent.db(), context: context).all()
    }
}
