import FluentKit
import Foundation
import LuminaVaultShared

/// HER-Projects — a named container that groups `Todo`s. Tenant-scoped.
/// Todos are note-backed (`VaultFile` with `metadata.isTodo`) and link to a
/// project via `VaultFileMetadata.projectID`; `todoCount` is computed on read.
final class Project: Model, TenantModel, @unchecked Sendable {
    static let schema = "projects"

    @ID(key: .id) var id: UUID?
    @Field(key: "tenant_id") var tenantID: UUID
    @Field(key: "name") var name: String
    @OptionalField(key: "description") var description: String?
    @Field(key: "archived") var archived: Bool
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {
        archived = false
    }

    init(
        id: UUID? = nil,
        tenantID: UUID,
        name: String,
        description: String? = nil,
        archived: Bool = false,
    ) {
        self.id = id
        self.tenantID = tenantID
        self.name = name
        self.description = description
        self.archived = archived
    }

    func toDTO(todoCount: Int? = nil) throws -> ProjectDTO {
        try ProjectDTO(
            id: requireID(),
            name: name,
            description: description,
            archived: archived,
            todoCount: todoCount,
            createdAt: createdAt ?? Date(),
        )
    }
}
