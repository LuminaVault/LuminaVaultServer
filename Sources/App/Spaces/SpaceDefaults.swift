import Foundation

/// Product-default Spaces seeded on first `POST /v1/vault/create`. Slugs are
/// part of the public API contract — never rename without a migration plan.
/// Icons are SF Symbol names so the iOS client can render without any
/// additional asset shipping.
enum SpaceDefaults {
    struct Entry: Sendable {
        let slug: String
        let name: String
        let icon: String
    }

    static let entries: [Entry] = [
        Entry(slug: "ai", name: "AI", icon: "sparkles"),
        Entry(slug: "stocks", name: "Stocks", icon: "chart.line.uptrend.xyaxis"),
        Entry(slug: "health", name: "Health", icon: "heart.fill"),
        Entry(slug: "work", name: "Work", icon: "briefcase.fill"),
        Entry(slug: "ideas", name: "Ideas", icon: "lightbulb.fill"),
    ]
}
