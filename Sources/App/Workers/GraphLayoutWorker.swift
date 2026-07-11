import FluentKit
import Foundation
import HummingbirdFluent
import Logging
import ServiceLifecycle
import SQLKit

/// HER-235 3D viz — recomputes each tenant's persisted 3D graph layout
/// (`GraphLayoutService`) so the clients render embedding-meaningful, stable
/// clusters without doing dimensionality reduction on-device.
///
/// `ServiceLifecycle.Service` that wakes every `tickInterval` (default one
/// hour). For each tenant it recomputes only when there is at least one
/// **embedded memory without coordinates** (i.e. new captures since the last
/// layout) or no layout has ever run — PCA is global, so any new memory shifts
/// the whole cloud, but we skip tenants with nothing new to avoid churn.
///
/// Single-replica (like `SynthesisWorker`): multi-replica would double-compute
/// harmlessly (idempotent overwrite) but wastefully — add advisory-lock leader
/// election when scaling out. Gated off in `lv.environment=test`.
actor GraphLayoutWorker: Service {
    let fluent: Fluent
    let layout: GraphLayoutService
    let logger: Logger
    let tickInterval: Duration

    init(
        fluent: Fluent,
        logger: Logger = Logger(label: "lv.graph.layout.worker"),
        tickInterval: Duration = .seconds(3600)
    ) {
        self.fluent = fluent
        layout = GraphLayoutService(fluent: fluent, logger: logger)
        self.logger = logger
        self.tickInterval = tickInterval
    }

    func run() async throws {
        logger.info("graph.layout.worker started (tick=\(tickInterval))")
        while !Task.isCancelled {
            do { try await tick() }
            catch { logger.warning("graph.layout.worker tick error: \(error)") }
            try? await Task.sleep(for: tickInterval)
        }
    }

    /// Single pass over all tenants. Returns the number of tenants relaid out.
    /// Exposed so tests can drive it deterministically.
    @discardableResult
    func tick() async throws -> Int {
        let users = try await User.query(on: fluent.db()).all()
        var relaid = 0
        for user in users {
            let tenantID = try user.requireID()
            do {
                if try await needsLayout(tenantID: tenantID) {
                    let count = try await layout.computeAndPersist(tenantID: tenantID)
                    if count > 0 { relaid += 1 }
                }
            } catch {
                logger.warning("graph.layout tenant=\(tenantID) error: \(error)")
            }
        }
        return relaid
    }

    private struct LayoutStatusRow: Decodable { let unlaid: Int }

    /// Cheap gate: recompute when any embedded memory lacks coordinates.
    private func needsLayout(tenantID: UUID) async throws -> Bool {
        guard let sql = fluent.db() as? any SQLDatabase else { return false }
        let row = try await sql.raw("""
        SELECT COUNT(*)::int AS unlaid
        FROM memories
        WHERE tenant_id = \(bind: tenantID) AND embedding IS NOT NULL AND graph_x IS NULL
        """).first(decoding: LayoutStatusRow.self)
        return (row?.unlaid ?? 0) > 0
    }
}
