import Foundation

/// HER-240a — in-memory descriptor of a tenant's Hermes container. Built from
/// the matching `HermesTenantContainer` row plus `apiServerKey` decrypted at
/// construction time. Passed to callers that need to talk to the container
/// (XaiOAuthService for `docker exec`, GrokController later for HTTP proxy).
struct HermesContainerHandle: Equatable {
    let tenantID: UUID
    /// Docker container name. Format: `hermes-tenant-{tenantID}`.
    let containerName: String
    /// Host port mapped to the container's API server (8642 inside).
    let port: Int
    /// Plain API_SERVER_KEY (decrypted from DB on construction). Passed in
    /// the `Authorization: Bearer …` header on every HTTP request to the
    /// container. Never logged.
    let apiServerKey: String
    let xaiConnectedAt: Date?

    /// Internal base URL used by the server to reach the container over the
    /// shared docker network. Container resolves by name on the network.
    var baseURL: String {
        "http://\(containerName):8642"
    }
}
