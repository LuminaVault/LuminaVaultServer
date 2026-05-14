import Foundation

struct EnrichedMetadata: Codable {
    var title: String?
    var description: String?
    var imageURL: String?
    var author: String?
    var url: String
    var transcript: String?
}

protocol URLEnricher: Sendable {
    func canHandle(url: URL) -> Bool
    func enrich(url: URL) async throws -> EnrichedMetadata
}

/// SSRF guard. Blocks the enricher from fetching internal/cloud-metadata
/// hosts when a user submits a hostile URL. Reject anything that is not
/// http(s), resolves to a private/loopback/link-local IP, or hits a host
/// that is itself a numeric private address.
enum URLEnricherGuard {
    static let maxBodyBytes = 2 * 1024 * 1024

    static func isPublic(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        guard let host = url.host?.lowercased(), !host.isEmpty else { return false }

        let blockedHosts: Set = [
            "localhost", "ip6-localhost", "ip6-loopback",
            "metadata.google.internal",
        ]
        if blockedHosts.contains(host) { return false }
        if host.hasSuffix(".internal") || host.hasSuffix(".local") { return false }

        return !isPrivateNumericHost(host)
    }

    /// Detects private IPv4 / IPv6 / link-local literals supplied as the host.
    /// Does not perform DNS — that resolution still happens in URLSession and is
    /// outside our control, but rejecting numeric private hosts removes the
    /// most direct SSRF vector.
    private static func isPrivateNumericHost(_ host: String) -> Bool {
        let stripped = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))

        // IPv4
        let parts = stripped.split(separator: ".").compactMap { UInt8($0) }
        if parts.count == 4 {
            switch (parts[0], parts[1]) {
            case (10, _): return true
            case (127, _): return true
            case (169, 254): return true
            case let (172, b) where (16 ... 31).contains(b): return true
            case (192, 168): return true
            case (0, _): return true
            case let (100, b) where (64 ... 127).contains(b): return true
            default: break
            }
        }

        // IPv6
        let lower = stripped.lowercased()
        if lower == "::1" || lower == "::" { return true }
        if lower.hasPrefix("fc") || lower.hasPrefix("fd") { return true }
        if lower.hasPrefix("fe80") { return true }

        return false
    }
}
