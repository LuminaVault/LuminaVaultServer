import FluentKit
import Foundation

/// Marker protocol for any Fluent model owned by a single tenant.
/// Schema MUST have a `tenant_id` UUID column (NOT NULL, indexed).
/// Models conform by exposing `var tenantID: UUID` backed by `@Field(key: "tenant_id")`.
protocol TenantModel: Model {
    var tenantID: UUID { get set }
}

extension TenantModel {
    static var tenantIDFieldKey: FieldKey { "tenant_id" }

    /// Tenant-scoped query — apply BEFORE any other filter.
    static func query(on database: any Database, tenantID: UUID) -> QueryBuilder<Self> {
        query(on: database).filter(tenantIDFieldKey, .equal, tenantID)
    }

    static func query(on database: any Database, context: AppRequestContext) throws -> QueryBuilder<Self> {
        try query(on: database, tenantID: context.requireTenantID())
    }
}
