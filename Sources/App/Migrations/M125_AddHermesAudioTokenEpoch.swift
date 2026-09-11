import FluentKit

/// Adds the revocation clock for scoped audio tokens.
///
/// A tenant's Hermes container holds a long-lived, narrowly-scoped JWT so it
/// can reach `/v1/audio/*` for speech-to-text. Those tokens are not tracked
/// individually — revoking one means moving this timestamp forward, after
/// which every token issued at or before it stops verifying.
///
/// `NULL` means "never revoked" and is the correct default for every existing
/// row: no audio tokens have been minted yet.
struct M125_AddHermesAudioTokenEpoch: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("users")
            .field("hermes_audio_token_epoch", .datetime)
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("users")
            .deleteField("hermes_audio_token_epoch")
            .update()
    }
}
