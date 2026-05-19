import Foundation
import Hummingbird

// HER-240a — server-local wire DTOs for `/v1/integrations/xai`. Defined
// here rather than in `LuminaVaultShared` because the shared package
// version graph across in-flight branches (HER-37, HER-244) makes a clean
// bump impractical right now. iOS client will land its own mirror in
// HER-240b; once the shared package settles these can move there per the
// repo's CLAUDE.md DTO policy (see HER-213 precedent for the same
// temporary server-local pattern).

/// GET /v1/integrations/xai — current state of the tenant's xAI Grok OAuth
/// connection. `tier` mirrors the User row's tier column.
struct XaiStatusResponse: Codable, Sendable, ResponseEncodable {
    let connected: Bool
    let tier: String
    let xaiConnectedAt: Date?
}

/// POST /v1/integrations/xai/start — the server returns an `authorizeURL`
/// the iOS client opens in a `WKWebView`. The opaque `sessionID` is echoed
/// back in `complete`. Server-side TTL is 10 minutes.
struct XaiStartResponse: Codable, Sendable, ResponseEncodable {
    let sessionID: String
    let authorizeURL: String
}

/// POST /v1/integrations/xai/complete — iOS posts the full callback URL it
/// captured from `WKWebView.decidePolicyFor` (host `127.0.0.1`, port `56121`,
/// path `/callback`, query `?code=…&state=…`).
struct XaiCompleteRequest: Codable, Sendable {
    let sessionID: String
    let callbackURL: String
}
