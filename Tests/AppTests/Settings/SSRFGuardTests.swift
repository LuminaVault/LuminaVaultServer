@testable import App
import Foundation
import Testing

/// HER-217 — `SSRFGuard` rejection tests. Uses a stub `HostResolver`
/// to pin DNS answers so tests don't depend on the test host's
/// network stack.
struct SSRFGuardTests {
    /// Stub resolver returning fixed addresses per host. Tests can also
    /// flip the answer mid-test to drive the DNS-rebinding path.
    final class StubResolver: HostResolver, @unchecked Sendable {
        var answers: [String: [String]]
        var resolvedHosts: [String] = []

        init(answers: [String: [String]] = [:]) {
            self.answers = answers
        }

        func resolve(host: String) async throws -> [String] {
            resolvedHosts.append(host)
            return answers[host] ?? []
        }
    }

    // MARK: - Scheme rejection

    @Test
    func `rejects ftp scheme`() async {
        let guardian = SSRFGuard(
            allowPrivateRanges: false,
            environment: "dev",
            resolver: StubResolver(answers: ["example.com": ["93.184.216.34"]]),
        )
        await #expect(throws: SSRFGuard.Rejection.schemeNotAllowed("ftp")) {
            _ = try await guardian.validate(rawURL: "ftp://example.com")
        }
    }

    @Test
    func `rejects http in prod`() async {
        let guardian = SSRFGuard(
            allowPrivateRanges: false,
            environment: "prod",
            resolver: StubResolver(answers: ["example.com": ["93.184.216.34"]]),
        )
        await #expect(throws: SSRFGuard.Rejection.schemeNotAllowed("http")) {
            _ = try await guardian.validate(rawURL: "http://example.com")
        }
    }

    @Test
    func `allows http in dev`() async throws {
        let guardian = SSRFGuard(
            allowPrivateRanges: false,
            environment: "dev",
            resolver: StubResolver(answers: ["example.com": ["93.184.216.34"]]),
        )
        let url = try await guardian.validate(rawURL: "http://example.com")
        #expect(url.host == "example.com")
    }

    // MARK: - Host literal rejection

    @Test
    func `rejects literal localhost`() async {
        let guardian = SSRFGuard(
            allowPrivateRanges: false,
            environment: "dev",
            resolver: StubResolver(),
        )
        await #expect(throws: SSRFGuard.Rejection.loopback("localhost")) {
            _ = try await guardian.validate(rawURL: "http://localhost")
        }
    }

    @Test
    func `rejects literal 127dot0dot0dot1`() async {
        let guardian = SSRFGuard(
            allowPrivateRanges: false,
            environment: "dev",
            resolver: StubResolver(answers: ["127.0.0.1": ["127.0.0.1"]]),
        )
        await #expect(throws: SSRFGuard.Rejection.loopback("127.0.0.1")) {
            _ = try await guardian.validate(rawURL: "http://127.0.0.1")
        }
    }

    // MARK: - Resolved-IP rejection

    @Test
    func `rejects host resolving to RFC1918 10dot8`() async {
        let resolver = StubResolver(answers: ["evil.com": ["10.0.0.5"]])
        let guardian = SSRFGuard(
            allowPrivateRanges: false,
            environment: "dev",
            resolver: resolver,
        )
        await #expect(throws: SSRFGuard.Rejection.privateAddress("10.0.0.5")) {
            _ = try await guardian.validate(rawURL: "http://evil.com")
        }
    }

    @Test
    func `rejects host resolving to RFC1918 192dot168`() async {
        let resolver = StubResolver(answers: ["evil.com": ["192.168.1.1"]])
        let guardian = SSRFGuard(
            allowPrivateRanges: false,
            environment: "dev",
            resolver: resolver,
        )
        await #expect(throws: SSRFGuard.Rejection.privateAddress("192.168.1.1")) {
            _ = try await guardian.validate(rawURL: "http://evil.com")
        }
    }

    @Test
    func `rejects host resolving to RFC1918 172dot16to31`() async {
        let resolver = StubResolver(answers: ["evil.com": ["172.20.0.1"]])
        let guardian = SSRFGuard(
            allowPrivateRanges: false,
            environment: "dev",
            resolver: resolver,
        )
        await #expect(throws: SSRFGuard.Rejection.privateAddress("172.20.0.1")) {
            _ = try await guardian.validate(rawURL: "http://evil.com")
        }
    }

    @Test
    func `rejects EC2 metadata 169dot254dot169dot254`() async {
        let resolver = StubResolver(answers: ["evil.com": ["169.254.169.254"]])
        let guardian = SSRFGuard(
            allowPrivateRanges: false,
            environment: "dev",
            resolver: resolver,
        )
        await #expect(throws: SSRFGuard.Rejection.linkLocal("169.254.169.254")) {
            _ = try await guardian.validate(rawURL: "http://evil.com")
        }
    }

    @Test
    func `rejects host resolving to IPv6 loopback`() async {
        let resolver = StubResolver(answers: ["evil.com": ["::1"]])
        let guardian = SSRFGuard(
            allowPrivateRanges: false,
            environment: "dev",
            resolver: resolver,
        )
        await #expect(throws: SSRFGuard.Rejection.loopback("::1")) {
            _ = try await guardian.validate(rawURL: "http://evil.com")
        }
    }

    @Test
    func `rejects host resolving to IPv6 unique-local`() async {
        let resolver = StubResolver(answers: ["evil.com": ["fc00::1"]])
        let guardian = SSRFGuard(
            allowPrivateRanges: false,
            environment: "dev",
            resolver: resolver,
        )
        await #expect(throws: SSRFGuard.Rejection.privateAddress("fc00::1")) {
            _ = try await guardian.validate(rawURL: "http://evil.com")
        }
    }

    @Test
    func `rejects 0dot0dot0dot0`() async {
        let resolver = StubResolver(answers: ["evil.com": ["0.0.0.0"]])
        let guardian = SSRFGuard(
            allowPrivateRanges: false,
            environment: "dev",
            resolver: resolver,
        )
        await #expect(throws: SSRFGuard.Rejection.privateAddress("0.0.0.0")) {
            _ = try await guardian.validate(rawURL: "http://evil.com")
        }
    }

    // MARK: - Acceptance + DNS rebinding

    @Test
    func `accepts public host`() async throws {
        let resolver = StubResolver(answers: ["api.example.com": ["93.184.216.34"]])
        let guardian = SSRFGuard(
            allowPrivateRanges: false,
            environment: "dev",
            resolver: resolver,
        )
        let url = try await guardian.validate(rawURL: "https://api.example.com")
        #expect(url.host == "api.example.com")
    }

    @Test
    func `re-resolves on every call (DNS rebinding defense)`() async throws {
        let resolver = StubResolver(answers: ["evil.com": ["93.184.216.34"]])
        let guardian = SSRFGuard(
            allowPrivateRanges: false,
            environment: "dev",
            resolver: resolver,
        )

        // First call: public IP → accepted.
        _ = try await guardian.validate(rawURL: "https://evil.com")

        // DNS provider rebinds to loopback.
        resolver.answers["evil.com"] = ["127.0.0.1"]

        // Second call MUST re-resolve and reject.
        await #expect(throws: SSRFGuard.Rejection.loopback("127.0.0.1")) {
            _ = try await guardian.validate(rawURL: "https://evil.com")
        }

        // Both calls round-tripped the resolver — no caching.
        #expect(resolver.resolvedHosts == ["evil.com", "evil.com"])
    }

    @Test
    func `unresolvable host throws unresolvable`() async {
        let guardian = SSRFGuard(
            allowPrivateRanges: false,
            environment: "dev",
            resolver: StubResolver(answers: [:]),
        )
        await #expect(throws: SSRFGuard.Rejection.unresolvable("ghost.example")) {
            _ = try await guardian.validate(rawURL: "https://ghost.example")
        }
    }

    @Test
    func `allowPrivateRanges opens loopback`() async throws {
        let resolver = StubResolver(answers: ["127.0.0.1": ["127.0.0.1"]])
        let guardian = SSRFGuard(
            allowPrivateRanges: true,
            environment: "dev",
            resolver: resolver,
        )
        let url = try await guardian.validate(rawURL: "http://127.0.0.1")
        #expect(url.host == "127.0.0.1")
    }

    // MARK: - Static helper coverage

    @Test
    func `parseIPv4 accepts dotted quad`() {
        let parsed = SSRFGuard.parseIPv4("192.168.1.1")
        #expect(parsed?.0 == 192)
        #expect(parsed?.1 == 168)
        #expect(parsed?.2 == 1)
        #expect(parsed?.3 == 1)
    }

    @Test
    func `parseIPv4 rejects non-numeric`() {
        #expect(SSRFGuard.parseIPv4("abc.def.ghi.jkl") == nil)
    }

    @Test
    func `parseIPv4 rejects out-of-range octet`() {
        #expect(SSRFGuard.parseIPv4("999.0.0.1") == nil)
    }
}
