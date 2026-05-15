import Foundation
import Network

/// HER-217 — URL allowlist for user-supplied gateway endpoints
/// (HER-197 follow-up).
///
/// User-supplied URLs are an SSRF attack surface: an attacker who can
/// PUT a BYO endpoint pointing at `http://169.254.169.254/...` (EC2
/// metadata), `http://10.0.0.1/admin`, or `http://localhost:8642` (the
/// managed Hermes itself) can pivot from a request-issuing user into
/// the server's network. This guard rejects those targets before any
/// `URLSession` call.
///
/// Two-phase check:
///   1. **PUT-time** (`validate(rawURL:)`): syntactic + resolved-host
///      check on the configured URL.
///   2. **Request-time** (`validate(rawURL:)` called again before each
///      `URLSession` dispatch): re-resolves the host. DNS rebinding
///      defense — `attacker.com` may have returned a public IP at
///      PUT-time and `127.0.0.1` now.
///
/// `LV_BYO_HERMES_ALLOW_PRIVATE=true` opens private ranges for local
/// dev only. The override is an env var (process-global), never a
/// per-request or per-user flag.
struct SSRFGuard {
    enum Rejection: Swift.Error, Equatable {
        case invalidURL
        case schemeNotAllowed(String)
        case hostMissing
        case privateAddress(String)
        case loopback(String)
        case linkLocal(String)
        case unresolvable(String)
    }

    /// `false` outside dev. When `true`, RFC1918 / loopback / link-local
    /// targets are allowed — for local Hermes instances on the same
    /// machine. Set via `LV_BYO_HERMES_ALLOW_PRIVATE`.
    let allowPrivateRanges: Bool

    /// `"prod"` blocks `http://`. Any other value allows it (dev, test,
    /// staging). Set via `LV_ENV`.
    let environment: String

    /// Resolves hostnames to IP literals. Tests inject a stub; prod uses
    /// the default `getaddrinfo`-backed implementation.
    let resolver: any HostResolver

    init(
        allowPrivateRanges: Bool,
        environment: String,
        resolver: any HostResolver = SystemHostResolver(),
    ) {
        self.allowPrivateRanges = allowPrivateRanges
        self.environment = environment
        self.resolver = resolver
    }

    /// Validates the URL syntactically, resolves its host, then rejects
    /// the resolved IPs against the private-range list. Re-call before
    /// each outbound request (DNS rebinding defense).
    func validate(rawURL: String) async throws -> URL {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else {
            throw Rejection.invalidURL
        }
        guard let scheme = url.scheme?.lowercased() else {
            throw Rejection.schemeNotAllowed("")
        }
        switch scheme {
        case "https":
            break
        case "http":
            if environment.lowercased() == "prod" {
                throw Rejection.schemeNotAllowed(scheme)
            }
        default:
            throw Rejection.schemeNotAllowed(scheme)
        }
        guard let host = url.host, !host.isEmpty else {
            throw Rejection.hostMissing
        }
        if Self.isHostnameLoopbackLiteral(host) {
            if allowPrivateRanges { return url }
            throw Rejection.loopback(host)
        }

        let addresses = try await resolver.resolve(host: host)
        guard !addresses.isEmpty else {
            throw Rejection.unresolvable(host)
        }
        for ip in addresses {
            try classify(ip: ip)
        }
        return url
    }

    /// Reject IPs in loopback / RFC1918 / link-local / metadata ranges.
    private func classify(ip: String) throws {
        if Self.isLoopback(ip) {
            if allowPrivateRanges { return }
            throw Rejection.loopback(ip)
        }
        if Self.isLinkLocal(ip) {
            if allowPrivateRanges { return }
            throw Rejection.linkLocal(ip)
        }
        if Self.isPrivate(ip) {
            if allowPrivateRanges { return }
            throw Rejection.privateAddress(ip)
        }
    }

    // MARK: - IP classification helpers (internal — tested directly)

    static func isHostnameLoopbackLiteral(_ host: String) -> Bool {
        let lower = host.lowercased()
        if lower == "localhost" { return true }
        if lower == "ip6-localhost" || lower == "ip6-loopback" { return true }
        // Numeric loopbacks survive `URL.host` extraction with or without
        // bracketing for IPv6.
        let stripped = lower.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return isLoopback(stripped)
    }

    static func isLoopback(_ ip: String) -> Bool {
        if ip == "::1" || ip == "0:0:0:0:0:0:0:1" { return true }
        // IPv4 loopback: 127.0.0.0/8.
        if let v4 = parseIPv4(ip), v4.0 == 127 { return true }
        return false
    }

    static func isLinkLocal(_ ip: String) -> Bool {
        // IPv4 link-local: 169.254.0.0/16 (covers EC2 metadata 169.254.169.254).
        if let v4 = parseIPv4(ip), v4.0 == 169, v4.1 == 254 { return true }
        // IPv6 link-local: fe80::/10.
        let lower = ip.lowercased()
        if lower.hasPrefix("fe80:") || lower.hasPrefix("fe80::") { return true }
        return false
    }

    static func isPrivate(_ ip: String) -> Bool {
        if let v4 = parseIPv4(ip) {
            // 10.0.0.0/8
            if v4.0 == 10 { return true }
            // 172.16.0.0/12
            if v4.0 == 172, (16...31).contains(v4.1) { return true }
            // 192.168.0.0/16
            if v4.0 == 192, v4.1 == 168 { return true }
            // 0.0.0.0/8 (wildcard / "this network") — never legitimate as a target.
            if v4.0 == 0 { return true }
        }
        let lower = ip.lowercased()
        // IPv6 unique-local: fc00::/7.
        if lower.hasPrefix("fc") || lower.hasPrefix("fd") {
            return true
        }
        // IPv6 mapped IPv4 (::ffff:a.b.c.d) — re-classify the embedded v4.
        if lower.hasPrefix("::ffff:") {
            let tail = String(lower.dropFirst("::ffff:".count))
            return isPrivate(tail) || isLoopback(tail) || isLinkLocal(tail)
        }
        return false
    }

    static func parseIPv4(_ ip: String) -> (Int, Int, Int, Int)? {
        let parts = ip.split(separator: ".")
        guard parts.count == 4 else { return nil }
        let nums = parts.compactMap { Int($0) }
        guard nums.count == 4, nums.allSatisfy({ (0...255).contains($0) }) else {
            return nil
        }
        return (nums[0], nums[1], nums[2], nums[3])
    }
}

/// Pluggable host resolution so tests can pin specific DNS answers and
/// exercise the DNS-rebinding revalidation path.
protocol HostResolver: Sendable {
    func resolve(host: String) async throws -> [String]
}

/// Default `getaddrinfo`-backed resolver.
struct SystemHostResolver: HostResolver {
    func resolve(host: String) async throws -> [String] {
        // IP literal short-circuit — `getaddrinfo` returns it unchanged,
        // but we can skip the syscall.
        if SSRFGuard.parseIPv4(host) != nil { return [host] }
        if host.contains(":") { return [host] }

        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM

        var result: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(host, nil, &hints, &result)
        guard rc == 0, let head = result else {
            throw SSRFGuard.Rejection.unresolvable(host)
        }
        defer { freeaddrinfo(head) }

        var addrs: [String] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = head
        while let node = cursor {
            var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let nrc = getnameinfo(
                node.pointee.ai_addr,
                node.pointee.ai_addrlen,
                &buf,
                socklen_t(buf.count),
                nil,
                0,
                NI_NUMERICHOST,
            )
            if nrc == 0 {
                let bytes = buf.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
                if let s = String(validating: bytes, as: UTF8.self) {
                    addrs.append(s)
                }
            }
            cursor = node.pointee.ai_next
        }
        return addrs
    }
}
