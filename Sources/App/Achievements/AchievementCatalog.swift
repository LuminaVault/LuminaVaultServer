import Foundation

/// Usage events that move achievement counters. Wired from the existing
/// controller hot-paths via `AchievementsService.record(tenantID:event:)`.
/// Extend by adding a case here, a `match` rule in `AchievementCatalog`,
/// and a single-line hook in the relevant controller.
enum AchievementEvent: String, Codable, Hashable, CaseIterable {
    case memoryUpserted = "memory_upserted"
    case chatCompleted = "chat_completed"
    case kbCompiled = "kb_compiled"
    case queryRan = "query_ran"
    case vaultUploaded = "vault_uploaded"
    case soulConfigured = "soul_configured"
    case spaceCreated = "space_created"
}

/// The four archetypes shown on the iOS "Forms" grid. Each archetype owns
/// a fixed set of sub-achievements; completing the whole set unlocks the
/// archetype's "true form."
enum AchievementArchetypeKey: String, Codable, Hashable, CaseIterable {
    case lightbringer
    case shadowlord
    case reignmaker
    case soulseeker

    var label: String {
        switch self {
        case .lightbringer: "Lightbringer"
        case .shadowlord: "Shadowlord"
        case .reignmaker: "Reignmaker"
        case .soulseeker: "Soulseeker"
        }
    }
}

/// One step inside an archetype. `key` is the canonical identifier
/// (`<archetype>.<slug>`) used as the row key in `achievement_progress`.
/// `target` is the inclusive threshold: once `progressCount >= target`
/// the sub is considered unlocked.
struct SubAchievement: Hashable, Codable {
    let key: String
    let label: String
    let event: AchievementEvent
    let target: Int64
}

struct AchievementArchetype: Hashable, Codable {
    let key: AchievementArchetypeKey
    let label: String
    let subs: [SubAchievement]
}

/// Static, code-defined catalog. Content is intentionally hand-curated and
/// versioned via `catalogVersion` so iOS can detect newly shipped entries
/// without a template fetch. Updates to thresholds or labels bump the
/// version; schema changes go through a migration.
///
/// Catalog content needs a product pass before launch but the scaffold
/// gives a sensible default that exercises every `AchievementEvent`.
struct AchievementCatalog {
    /// Bump on any content edit so iOS clients can flag new entries.
    let catalogVersion: Int
    let archetypes: [AchievementArchetype]

    static let current = AchievementCatalog(
        catalogVersion: 1,
        archetypes: [
            AchievementArchetype(
                key: .lightbringer,
                label: AchievementArchetypeKey.lightbringer.label,
                subs: [
                    SubAchievement(key: "lightbringer.first-spark", label: "First Spark", event: .memoryUpserted, target: 1),
                    SubAchievement(key: "lightbringer.kindled-mind", label: "Kindled Mind", event: .memoryUpserted, target: 10),
                    SubAchievement(key: "lightbringer.illuminator", label: "Illuminator", event: .memoryUpserted, target: 50),
                    SubAchievement(key: "lightbringer.lightbearer", label: "Lightbearer", event: .memoryUpserted, target: 200),
                ],
            ),
            AchievementArchetype(
                key: .shadowlord,
                label: AchievementArchetypeKey.shadowlord.label,
                subs: [
                    SubAchievement(key: "shadowlord.shadow-touched", label: "Shadow-touched", event: .soulConfigured, target: 1),
                    SubAchievement(key: "shadowlord.deep-listener", label: "Deep Listener", event: .chatCompleted, target: 5),
                    SubAchievement(key: "shadowlord.night-walker", label: "Night Walker", event: .chatCompleted, target: 25),
                    SubAchievement(key: "shadowlord.umbral-sovereign", label: "Umbral Sovereign", event: .chatCompleted, target: 100),
                ],
            ),
            AchievementArchetype(
                key: .reignmaker,
                label: AchievementArchetypeKey.reignmaker.label,
                subs: [
                    SubAchievement(key: "reignmaker.first-edict", label: "First Edict", event: .queryRan, target: 1),
                    SubAchievement(key: "reignmaker.tactician", label: "Tactician", event: .queryRan, target: 10),
                    SubAchievement(key: "reignmaker.strategist", label: "Strategist", event: .kbCompiled, target: 5),
                    SubAchievement(key: "reignmaker.regent", label: "Regent", event: .queryRan, target: 100),
                ],
            ),
            AchievementArchetype(
                key: .soulseeker,
                label: AchievementArchetypeKey.soulseeker.label,
                subs: [
                    SubAchievement(key: "soulseeker.first-relic", label: "First Relic", event: .vaultUploaded, target: 1),
                    SubAchievement(key: "soulseeker.collector", label: "Collector", event: .vaultUploaded, target: 10),
                    SubAchievement(key: "soulseeker.cartographer", label: "Cartographer", event: .spaceCreated, target: 3),
                    SubAchievement(key: "soulseeker.soulkeeper", label: "Soulkeeper", event: .vaultUploaded, target: 100),
                ],
            ),
        ],
    )

    /// All sub-achievements whose counter increments on `event`. The result
    /// is order-preserving over `archetypes` so callers can rely on it for
    /// deterministic processing.
    func subs(matching event: AchievementEvent) -> [SubAchievement] {
        archetypes.flatMap { archetype in
            archetype.subs.filter { $0.event == event }
        }
    }

    /// Flat sub map keyed by `SubAchievement.key`. Used by the controller
    /// when joining `achievement_progress` rows to catalog metadata.
    var subsByKey: [String: SubAchievement] {
        var out: [String: SubAchievement] = [:]
        for archetype in archetypes {
            for sub in archetype.subs {
                out[sub.key] = sub
            }
        }
        return out
    }
}
