import Foundation

// `Network` (Apple high-level framework) was imported here historically
// but the SSRF guard only uses POSIX `getaddrinfo` / `getnameinfo`,
// which come from Foundation on both Darwin and Linux. Importing
// `Network` breaks the Linux build on CI (Hummingbird's Linux runner
// does not ship a `Network` module). Drop the import.

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

    /// When `true`, `http://` endpoints are rejected (scheme must be
    /// `https`). Defaults to `false` — plain `http` is allowed so
    /// self-hosters can point at a bare-IP / non-TLS Hermes, at the cost
    /// of a plaintext auth header (the iOS client warns about this).
    /// Set via `BYO_HERMES_REQUIRE_HTTPS=true` for operators who want to
    /// force TLS. Independent of `allowPrivateRanges`: private/loopback/
    /// link-local/metadata targets stay blocked regardless of scheme.
    let requireHTTPS: Bool

    /// Tailnet carve-out (`BYO_HERMES_ALLOW_TAILNET_HTTP`, default `true`).
    /// Tailscale endpoints (IPv4 100.64.0.0/10, IPv6 fd7a:115c:a1e0::/48)
    /// ride an authenticated WireGuard tunnel, so `http://` there is not
    /// plaintext on the wire. When `true`:
    ///   - `requireHTTPS` is waived for hosts whose *every* resolved
    ///     address is a Tailscale address (mixed tailnet+public answers
    ///     stay rejected — a rebinding name must not smuggle http out).
    ///   - Tailscale IPv6 addresses are exempt from the fc00::/7
    ///     unique-local block (they'd otherwise fail even over https).
    /// A tailnet target is only reachable if the operator deliberately
    /// joined this server to that tailnet; for everyone else it's
    /// unroutable, so the default-open stance doesn't widen SSRF reach.
    let allowTailnetHTTP: Bool

    /// Resolves hostnames to IP literals. Tests inject a stub; prod uses
    /// the default `getaddrinfo`-backed implementation.
    let resolver: any HostResolver

    init(
        allowPrivateRanges: Bool,
        requireHTTPS: Bool,
        allowTailnetHTTP: Bool = true,
        resolver: any HostResolver = SystemHostResolver()
    ) {
        self.allowPrivateRanges = allowPrivateRanges
        self.requireHTTPS = requireHTTPS
        self.allowTailnetHTTP = allowTailnetHTTP
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
        // `http` under `requireHTTPS` isn't rejected here: the tailnet
        // carve-out needs the resolved addresses first. Deferred to after
        // resolution below.
        var httpPendingTailnetCheck = false
        switch scheme {
        case "https":
            break
        case "http":
            if requireHTTPS {
                guard allowTailnetHTTP else {
                    throw Rejection.schemeNotAllowed(scheme)
                }
                httpPendingTailnetCheck = true
            }
        default:
            throw Rejection.schemeNotAllowed(scheme)
        }
        guard let host = url.host, !host.isEmpty else {
            throw Rejection.hostMissing
        }
        if Self.isHostnameLoopbackLiteral(host) {
            // Loopback is never a tailnet address, so the deferred http
            // rejection fires even when private ranges are open.
            if httpPendingTailnetCheck { throw Rejection.schemeNotAllowed(scheme) }
            if allowPrivateRanges { return url }
            throw Rejection.loopback(host)
        }

        let addresses = try await resolver.resolve(host: host)
        guard !addresses.isEmpty else {
            throw Rejection.unresolvable(host)
        }
        if httpPendingTailnetCheck, !addresses.allSatisfy(Self.isTailscale) {
            throw Rejection.schemeNotAllowed(scheme)
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
        // Tailscale IPv6 sits inside fc00::/7, so this exemption must run
        // before the unique-local block or MagicDNS AAAA answers fail
        // validation even over https.
        if Self.isTailscale(ip), allowTailnetHTTP { return }
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

    /// Tailscale addresses: IPv4 CGNAT 100.64.0.0/10 (Tailscale assigns
    /// every node from this block) and IPv6 fd7a:115c:a1e0::/48
    /// (Tailscale's fixed ULA prefix).
    static func isTailscale(_ ip: String) -> Bool {
        if let v4 = parseIPv4(ip) {
            return v4.0 == 100 && (64 ... 127).contains(v4.1)
        }
        return ip.lowercased().hasPrefix("fd7a:115c:a1e0:")
    }

    static func isPrivate(_ ip: String) -> Bool {
        if let v4 = parseIPv4(ip) {
            // 10.0.0.0/8
            if v4.0 == 10 { return true }
            // 172.16.0.0/12
            if v4.0 == 172, (16 ... 31).contains(v4.1) { return true }
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
        guard nums.count == 4, nums.allSatisfy({ (0 ... 255).contains($0) }) else {
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
        // `SOCK_STREAM` is `Int32` on Darwin but `__socket_type` (a C
        // enum) on Glibc. Cast via the underlying `Int32` ABI so the
        // assignment compiles on both platforms.
        #if canImport(Glibc)
            hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
        #else
            hints.ai_socktype = SOCK_STREAM
        #endif

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
                NI_NUMERICHOST
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
