import LuminaVaultShared

/// Server-owned defaults for users who choose LuminaVault-managed inference.
/// Clients render the effective values returned by the API; they do not own
/// or persist a separate managed-model policy.
enum ManagedLLMDefaults {
    static let provider: ProviderID = .openRouter
    static let model = "deepseek/deepseek-v4-flash"
}
