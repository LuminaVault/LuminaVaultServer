import Foundation

/// HER-197 scaffold — URL allowlist for user-supplied gateway endpoints.
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

    /// Validates the URL syntactically, resolves its host, then rejects
    /// the resolved IPs against the private-range list. Re-call before
    /// each outbound request (DNS rebinding defense).
    func validate(rawURL _: String) async throws -> URL {
        throw Rejection.invalidURL
    }
}
