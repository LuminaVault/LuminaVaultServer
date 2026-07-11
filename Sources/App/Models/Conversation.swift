import FluentKit
import Foundation
import LuminaVaultShared

/// HER-37 — a persisted multi-turn chat thread backing the "thinking
/// workspace" continuity surface on the Think tab. Tenant-scoped; cascade
/// on user delete via M44.
final class Conversation: Model, TenantModel, @unchecked Sendable {
    static let schema = "conversations"

    @ID(key: .id) var id: UUID?
    @Field(key: "tenant_id") var tenantID: UUID
    @Field(key: "title") var title: String
    @OptionalField(key: "space_id") var spaceID: UUID?
    @Field(key: "pinned_memory_ids") var pinnedMemoryIDs: [UUID]
    @OptionalField(key: "route_provider") var routeProvider: String?
    @OptionalField(key: "route_model") var routeModel: String?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {
        pinnedMemoryIDs = []
    }

    init(
        id: UUID? = nil,
        tenantID: UUID,
        title: String,
        spaceID: UUID? = nil,
        pinnedMemoryIDs: [UUID] = [],
        routeOverride: RouterModelRouteDTO? = nil
    ) {
        self.id = id
        self.tenantID = tenantID
        self.title = title
        self.spaceID = spaceID
        self.pinnedMemoryIDs = pinnedMemoryIDs
        routeProvider = routeOverride?.provider.rawValue
        routeModel = routeOverride?.model
    }

    /// Convert to the wire DTO. Falls back to "now" for timestamps when
    /// the row hasn't been persisted yet (shouldn't happen in HTTP paths,
    /// but the field is `Date?` per Fluent's `@Timestamp`).
    func toDTO() throws -> ConversationDTO {
        try ConversationDTO(
            id: requireID(),
            title: title,
            spaceId: spaceID,
            createdAt: createdAt ?? Date(),
            updatedAt: updatedAt ?? createdAt ?? Date(),
            pinnedMemoryIDs: pinnedMemoryIDs,
            routeOverride: routeOverride
        )
    }

    var routeOverride: RouterModelRouteDTO? {
        guard let routeProvider,
              let provider = ProviderID(rawValue: routeProvider),
              let routeModel,
              !routeModel.isEmpty
        else { return nil }
        return RouterModelRouteDTO(provider: provider, model: routeModel)
    }
}
