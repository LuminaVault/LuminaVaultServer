import FluentKit
import Foundation

/// User-defined organizing folder ("AI", "Stocks", "Health"...). One row
/// per logical folder under `<rawRoot>/<slug>/`. Slug is locked at create
/// time so the on-disk path stays stable across rename of the display name.
final class Space: Model, TenantModel, @unchecked Sendable {
    static let schema = "spaces"

    @ID(key: .id) var id: UUID?
    @Field(key: "tenant_id") var tenantID: UUID
    @Field(key: "name") var name: String
    @Field(key: "slug") var slug: String
    @OptionalField(key: "description") var spaceDescription: String?
    @OptionalField(key: "color") var color: String?
    @OptionalField(key: "icon") var icon: String?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        tenantID: UUID,
        name: String,
        slug: String,
        description: String? = nil,
        color: String? = nil,
        icon: String? = nil,
    ) {
        self.id = id
        self.tenantID = tenantID
        self.name = name
        self.slug = slug
        spaceDescription = description
        self.color = color
        self.icon = icon
    }
}
