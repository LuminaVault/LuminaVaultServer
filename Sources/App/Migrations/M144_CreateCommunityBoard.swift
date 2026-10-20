import FluentKit
import SQLKit

/// The global community board: one board every signed-in user shares, across
/// vaults. Unlike nearly every other table it is not tenant-scoped, so nothing
/// here may point at vault data. Authors are `community_profiles` (a public
/// handle + display name), never the account's username or email.
///
/// `community_daily_posts.day` is the one-a-day cap for the AI Daily Post:
/// `DailyPostWorker` claims the day with `ON CONFLICT DO NOTHING`, so two
/// replicas racing for the same day cannot both publish.
struct M144_CreateCommunityBoard: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw MigrationError.requiresSQL
        }
        try await sql.raw("""
        CREATE TABLE IF NOT EXISTS community_profiles (
            id UUID PRIMARY KEY,
            user_id UUID NOT NULL UNIQUE REFERENCES users(id) ON DELETE CASCADE,
            handle TEXT NOT NULL,
            display_name TEXT NOT NULL,
            terms_version INT NOT NULL,
            terms_accepted_at TIMESTAMPTZ NOT NULL,
            posting_suspended_until TIMESTAMPTZ,
            created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
            updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
        )
        """).run()
        try await sql.raw("""
        CREATE UNIQUE INDEX IF NOT EXISTS community_profiles_handle_lower
        ON community_profiles (lower(handle))
        """).run()

        try await sql.raw("""
        CREATE TABLE IF NOT EXISTS community_posts (
            id UUID PRIMARY KEY,
            parent_id UUID REFERENCES community_posts(id) ON DELETE CASCADE,
            author_kind TEXT NOT NULL CHECK (author_kind IN ('user', 'ai')),
            author_profile_id UUID REFERENCES community_profiles(id) ON DELETE CASCADE,
            title TEXT,
            body TEXT NOT NULL,
            status TEXT NOT NULL
                CHECK (status IN ('pending', 'visible', 'rejected', 'hidden', 'deleted')),
            moderation_category TEXT,
            moderation_attempts INT NOT NULL DEFAULT 0,
            moderated_at TIMESTAMPTZ,
            hidden_reason TEXT,
            reply_count INT NOT NULL DEFAULT 0,
            reaction_count INT NOT NULL DEFAULT 0,
            last_activity_at TIMESTAMPTZ NOT NULL DEFAULT now(),
            created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
            updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
            CHECK ((author_kind = 'user') = (author_profile_id IS NOT NULL)),
            CHECK ((parent_id IS NULL) = (title IS NOT NULL)),
            CHECK (char_length(body) <= 4000),
            CHECK (title IS NULL OR char_length(title) <= 120)
        )
        """).run()
        try await sql.raw("""
        CREATE INDEX IF NOT EXISTS community_posts_feed
        ON community_posts (last_activity_at DESC, id DESC)
        WHERE parent_id IS NULL AND status = 'visible'
        """).run()
        try await sql.raw("""
        CREATE INDEX IF NOT EXISTS community_posts_replies
        ON community_posts (parent_id, created_at, id)
        WHERE parent_id IS NOT NULL
        """).run()
        try await sql.raw("""
        CREATE INDEX IF NOT EXISTS community_posts_author
        ON community_posts (author_profile_id, created_at DESC)
        """).run()
        try await sql.raw("""
        CREATE INDEX IF NOT EXISTS community_posts_pending
        ON community_posts (created_at) WHERE status = 'pending'
        """).run()

        try await sql.raw("""
        CREATE TABLE IF NOT EXISTS community_daily_posts (
            day DATE PRIMARY KEY,
            status TEXT NOT NULL CHECK (status IN ('claimed', 'published', 'failed', 'skipped')),
            attempts INT NOT NULL DEFAULT 0,
            post_id UUID REFERENCES community_posts(id) ON DELETE SET NULL,
            theme_id TEXT,
            topic_key TEXT,
            source_kind TEXT CHECK (source_kind IN ('curated', 'trend', 'community')),
            source_urls JSONB NOT NULL DEFAULT '[]'::jsonb,
            model TEXT,
            last_error TEXT,
            claimed_at TIMESTAMPTZ,
            updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
        )
        """).run()

        try await sql.raw("""
        CREATE TABLE IF NOT EXISTS community_reports (
            id UUID PRIMARY KEY,
            post_id UUID NOT NULL REFERENCES community_posts(id) ON DELETE CASCADE,
            reporter_profile_id UUID NOT NULL REFERENCES community_profiles(id) ON DELETE CASCADE,
            reason TEXT NOT NULL CHECK (reason IN (
                'spam', 'harassment', 'hate', 'sexual', 'violence',
                'self_harm', 'misinformation', 'other'
            )),
            note TEXT CHECK (note IS NULL OR char_length(note) <= 500),
            status TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'actioned', 'dismissed')),
            created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
            resolved_at TIMESTAMPTZ,
            resolved_by_user_id UUID REFERENCES users(id) ON DELETE SET NULL,
            UNIQUE (post_id, reporter_profile_id)
        )
        """).run()
        try await sql.raw("""
        CREATE INDEX IF NOT EXISTS community_reports_open
        ON community_reports (post_id) WHERE status = 'open'
        """).run()

        try await sql.raw("""
        CREATE TABLE IF NOT EXISTS community_blocks (
            blocker_profile_id UUID NOT NULL REFERENCES community_profiles(id) ON DELETE CASCADE,
            blocked_profile_id UUID NOT NULL REFERENCES community_profiles(id) ON DELETE CASCADE,
            created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
            PRIMARY KEY (blocker_profile_id, blocked_profile_id),
            CHECK (blocker_profile_id <> blocked_profile_id)
        )
        """).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw MigrationError.requiresSQL
        }
        for table in ["community_blocks", "community_reports", "community_daily_posts", "community_posts", "community_profiles"] {
            try await sql.raw("DROP TABLE IF EXISTS \(unsafeRaw: table)").run()
        }
    }
}

private enum MigrationError: Error { case requiresSQL }
