import FluentKit
import Foundation
import HummingbirdFluent
import Logging
import LuminaVaultShared
import SQLKit

/// Per-tenant storage ceiling.
///
/// Nothing bounded total stored bytes before this. Per-*file* limits existed
/// (2 GiB per ingestion item, 5 GiB per batch, 10 MiB for a transcribe body),
/// but a tenant could repeat a 5 GiB batch indefinitely: nothing summed what
/// they already held. Every byte also lands in the nightly backup under 7/4/6
/// retention, so a runaway tenant multiplies into the backup volume too.
///
/// The sum comes from `vault_files.size_bytes`, which is maintained by the
/// write paths and replaced in place when a path is rewritten, so it needs no
/// new accounting table and no backfill. It is a `SUM` over one indexed
/// column per check — cheap at the sizes this gates, and only ever run on the
/// ingestion entry point rather than per chunk.
struct StorageQuotaService: Sendable {
    /// What a tier may store, in bytes.
    ///
    /// `nil` is unlimited; `0` is "may not grow at all". They must be
    /// distinct: expressing "no growth" as a zero *ceiling* reads as no
    /// ceiling under any `limit > 0` guard, which would hand a lapsed tenant
    /// unlimited storage — the exact opposite of the intent.
    struct Limits: Sendable, Equatable {
        let trial: Int64?
        let pro: Int64?
        let ultimate: Int64?
        /// A lapsed tenant keeps read and export — that is the whole content
        /// of the tier — so its ceiling only has to stop *growth*.
        let lapsed: Int64?
        /// Free keeps capture, so unlike `lapsed` it needs a real ceiling
        /// rather than zero. It is also the one tier `LapseArchiverJob` never
        /// touches, so whatever a free vault holds, it holds indefinitely —
        /// this number is the only thing bounding that.
        let free: Int64?

        static let `default` = Limits(
            trial: 5 * 1024 * 1024 * 1024,
            pro: 100 * 1024 * 1024 * 1024,
            ultimate: 1024 * 1024 * 1024 * 1024,
            lapsed: 0,
            free: 1024 * 1024 * 1024
        )

        func bytes(for tier: UserTier) -> Int64? {
            switch tier {
            case .trial: trial
            case .pro: pro
            case .ultimate: ultimate
            case .free: free
            case .lapsed, .archived: lapsed
            }
        }
    }

    enum Decision: Sendable, Equatable {
        case allow
        /// Over the ceiling. `used` and `limit` are surfaced to the caller so
        /// the message can say how much room is left rather than just "no".
        case deny(used: Int64, limit: Int64)
    }

    let fluent: Fluent
    let limits: Limits
    let enabled: Bool
    let logger: Logger

    init(fluent: Fluent, limits: Limits = .default, enabled: Bool = true, logger: Logger) {
        self.fluent = fluent
        self.limits = limits
        self.enabled = enabled
        self.logger = logger
    }

    /// Bytes this tenant currently holds in the vault.
    func usedBytes(tenantID: UUID) async -> Int64 {
        guard let sql = fluent.db() as? any SQLDatabase else { return 0 }
        do {
            let row = try await sql.raw("""
            SELECT COALESCE(SUM(size_bytes), 0) AS total
            FROM vault_files WHERE tenant_id = \(bind: tenantID)
            """).first()
            return (try? row?.decode(column: "total", as: Int64.self)) ?? 0
        } catch {
            logger.error("storage quota sum failed", metadata: [
                "tenant_id": .string(tenantID.uuidString),
                "error": .string("\(error)"),
            ])
            return 0
        }
    }

    /// Whether `incomingBytes` more may be written.
    ///
    /// Fails **open** on a metering error — `usedBytes` returns 0 and the
    /// check passes. A storage-accounting blip must not block a paying
    /// customer's upload; the failure it guards against accrues over days,
    /// not in the seconds an outage lasts.
    func check(tenantID: UUID, tier: UserTier, incomingBytes: Int64) async -> Decision {
        guard enabled else { return .allow }
        // nil is unlimited. A zero limit is *not* — it denies any growth.
        guard let limit = limits.bytes(for: tier) else { return .allow }
        let used = await usedBytes(tenantID: tenantID)
        guard used + Swift.max(0, incomingBytes) > limit else { return .allow }
        return .deny(used: used, limit: limit)
    }

    /// Human-readable ceiling message for a 413.
    static func message(used: Int64, limit: Int64) -> String {
        "storage quota exceeded: \(format(used)) of \(format(limit)) used"
    }

    static func format(_ bytes: Int64) -> String {
        let units: [(Int64, String)] = [
            (1024 * 1024 * 1024 * 1024, "TiB"),
            (1024 * 1024 * 1024, "GiB"),
            (1024 * 1024, "MiB"),
            (1024, "KiB"),
        ]
        for (scale, suffix) in units where bytes >= scale {
            let whole = Double(bytes) / Double(scale)
            return String(format: "%.1f %@", whole, suffix)
        }
        return "\(bytes) B"
    }
}

extension StorageQuotaService {
    /// Maps a configured integer onto the `Limits` sentinel: a negative value
    /// means unlimited, everything else (including 0, which denies growth) is
    /// taken literally.
    static func limit(_ configured: Int) -> Int64? {
        configured < 0 ? nil : Int64(configured)
    }
}
