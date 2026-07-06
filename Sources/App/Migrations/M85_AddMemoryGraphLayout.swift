import FluentKit

/// HER-235 3D viz — persist the precomputed 3D layout coordinate for each
/// memory so the web + iOS clients render an identical, jitter-free cluster.
/// Coordinates are derived by `GraphLayoutService` (PCA top-3 over the memory
/// embeddings) and refreshed by `GraphLayoutWorker`. All nullable: a row with
/// no coords yet (or a memory that has no embedding) is force-directed by the
/// client instead. `graph_layout_at` is the last-computed timestamp, used by
/// the worker to decide when a tenant's layout is stale.
struct M85_AddMemoryGraphLayout: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("memories")
            .field("graph_x", .double)
            .field("graph_y", .double)
            .field("graph_z", .double)
            .field("graph_layout_at", .datetime)
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("memories")
            .deleteField("graph_x")
            .deleteField("graph_y")
            .deleteField("graph_z")
            .deleteField("graph_layout_at")
            .update()
    }
}
