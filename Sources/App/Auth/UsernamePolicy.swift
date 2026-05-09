import Foundation

enum UsernamePolicy {
    static let pattern = #"^[a-z0-9][a-z0-9-]{2,30}$"#
    static let reserved: Set<String> = [
        "admin", "root", "hermes", "system", "support", "api", "www", "luminavault"
    ]

    static func normalize(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func validate(_ raw: String) throws -> String {
        let s = normalize(raw)
        guard s.range(of: pattern, options: .regularExpression) != nil,
              !reserved.contains(s)
        else { throw AuthError.invalidUsername }
        return s
    }

    /// Generates a placeholder username for OAuth-created users who didn't supply one.
    static func placeholder() -> String {
        "oauth-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8).lowercased()
    }
}
