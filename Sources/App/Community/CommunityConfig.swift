import Configuration
import Foundation

/// Switches for the community board, read once at boot. Changing one is a
/// values change in the infra repo, so each is a kill switch rather than a
/// tuning knob:
///
/// - `COMMUNITY_ENABLED` — the whole board. Off: `/me` says `enabled:false`,
///   every other route 503s and clients hide the entry.
/// - `COMMUNITY_POSTING_ENABLED` — member writes. Off: the board is read-only.
///   The switch to flip during abuse.
/// - `COMMUNITY_DAILY_POST_ENABLED` — the AI Daily Post.
/// - `COMMUNITY_DAILY_POST_HOUR_UTC` — start of the two-hour publish window.
struct CommunityConfig: Sendable, Equatable {
    var enabled: Bool
    var postingEnabled: Bool
    var dailyPostEnabled: Bool
    var dailyPostHourUTC: Int

    /// Bump when the Community Guidelines change; members re-accept before
    /// they can post again.
    static let termsVersion = 1
    /// Caption every AI post carries. Clients show it verbatim.
    static let aiLabel = "AI-generated · Daily Post"
    static let maxThreadsPerDay = 10
    static let maxRepliesPerDay = 60
    /// Distinct open reports that take a post off the board until a
    /// moderator rules on it.
    static let autoHideReportThreshold = 3

    static let disabled = Self(enabled: false, postingEnabled: false, dailyPostEnabled: false, dailyPostHourUTC: 12)

    init(enabled: Bool, postingEnabled: Bool, dailyPostEnabled: Bool, dailyPostHourUTC: Int) {
        self.enabled = enabled
        self.postingEnabled = postingEnabled
        self.dailyPostEnabled = dailyPostEnabled
        self.dailyPostHourUTC = min(max(dailyPostHourUTC, 0), 23)
    }

    init(reader: ConfigReader) {
        func flag(_ key: String, _ fallback: Bool) -> Bool {
            reader.string(forKey: ConfigKey(key), default: fallback ? "true" : "false").lowercased() == "true"
        }
        self.init(
            enabled: flag("community.enabled", false),
            postingEnabled: flag("community.postingEnabled", true),
            dailyPostEnabled: flag("community.dailyPost.enabled", false),
            dailyPostHourUTC: Int(reader.string(forKey: "community.dailyPost.hourUtc", default: "12")) ?? 12
        )
    }
}
