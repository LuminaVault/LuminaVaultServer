import Foundation
import Hummingbird
import HummingbirdFluent
import Logging
import LuminaVaultShared
import SQLKit

/// The global community board (M144). Every query here is cross-tenant, so
/// the one rule that keeps vault data out is structural: responses are built
/// only from `postProjection` (posts joined to profiles, handle + display name)
/// and never from `User`. The account's username, email and id stay server
/// side.
struct CommunityService: Sendable {
    let fluent: Fluent
    let config: CommunityConfig
    let moderator: any CommunityModerating
    let logger: Logger

    /// Who is reading. `profileID` is nil until the member sets up a profile;
    /// they can read, but not post, report or block.
    struct Viewer: Sendable, Equatable {
        let userID: UUID
        let profileID: UUID?
    }

    enum ErrorCode: String {
        case disabled = "community_disabled"
        case postingDisabled = "community_posting_disabled"
        case profileRequired = "community_profile_required"
        case termsRequired = "terms_required"
        case postingSuspended = "posting_suspended"
        case handleTaken = "handle_taken"
        case invalidHandle = "invalid_handle"
        case invalidDisplayName = "invalid_display_name"
        case invalidTitle = "invalid_title"
        case invalidBody = "invalid_body"
        case dailyLimit = "daily_limit_reached"
        case rejected = "moderation_rejected"
        case notFound = "post_not_found"
        case invalidCursor = "invalid_cursor"
        case cannotReportOwn = "cannot_report_own_post"
        case cannotBlockSelf = "cannot_block_self"
    }

    static let reservedHandles: Set<String> = [
        "admin", "administrator", "ai", "daily", "dailypost", "lumina", "luminavault",
        "moderator", "mod", "official", "staff", "support", "system", "team",
    ]
    static let handlePattern = #"^[a-z0-9_]{3,20}$"#
    static let maxPageSize = 50

    // MARK: - Me / profile

    func me(viewer userID: UUID, isModerator: Bool) async throws -> CommunityMeDTO {
        guard config.enabled else {
            return CommunityMeDTO(
                enabled: false, postingEnabled: false, profile: nil,
                termsVersionRequired: CommunityConfig.termsVersion, isModerator: false
            )
        }
        return try await CommunityMeDTO(
            enabled: true,
            postingEnabled: config.postingEnabled,
            profile: profile(userID: userID).map(Self.profileDTO),
            termsVersionRequired: CommunityConfig.termsVersion,
            isModerator: isModerator
        )
    }

    func viewer(userID: UUID) async throws -> Viewer {
        try await Viewer(userID: userID, profileID: profile(userID: userID)?.id)
    }

    func upsertProfile(userID: UUID, username: String, request: CommunityProfileUpsertRequest) async throws -> CommunityProfileDTO {
        let handle = request.handle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let displayName = request.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidHandle(handle, username: username) else {
            throw HTTPError(.unprocessableContent, message: ErrorCode.invalidHandle.rawValue)
        }
        guard (1 ... 40).contains(displayName.count), CommunityContentFilter.check(displayName) == nil else {
            throw HTTPError(.unprocessableContent, message: ErrorCode.invalidDisplayName.rawValue)
        }
        guard request.acceptTerms, request.termsVersion == CommunityConfig.termsVersion else {
            throw HTTPError(.unprocessableContent, message: ErrorCode.termsRequired.rawValue)
        }
        let sql = try sql()
        let taken = try await sql.raw("""
        SELECT 1 AS hit FROM community_profiles
        WHERE lower(handle) = \(bind: handle) AND user_id <> \(bind: userID)
        """).first()
        if taken != nil {
            throw HTTPError(.conflict, message: ErrorCode.handleTaken.rawValue)
        }
        let now = Date()
        do {
            try await sql.raw("""
            INSERT INTO community_profiles
                (id, user_id, handle, display_name, terms_version, terms_accepted_at, created_at, updated_at)
            VALUES (\(bind: UUID()), \(bind: userID), \(bind: handle), \(bind: displayName),
                    \(bind: request.termsVersion), \(bind: now), \(bind: now), \(bind: now))
            ON CONFLICT (user_id) DO UPDATE SET
                handle = EXCLUDED.handle,
                display_name = EXCLUDED.display_name,
                terms_version = EXCLUDED.terms_version,
                terms_accepted_at = EXCLUDED.terms_accepted_at,
                updated_at = EXCLUDED.updated_at
            """).run()
        } catch {
            // The pre-check above lost a race on lower(handle).
            logger.info("community.profile upsert conflict: \(String(reflecting: error))")
            throw HTTPError(.conflict, message: ErrorCode.handleTaken.rawValue)
        }
        guard let row = try await profile(userID: userID) else {
            throw HTTPError(.internalServerError, message: "profile_not_saved")
        }
        return Self.profileDTO(row)
    }

    static func isValidHandle(_ handle: String, username: String) -> Bool {
        handle.range(of: handlePattern, options: .regularExpression) != nil
            && !reservedHandles.contains(handle)
            // The username is a login identifier (passkey lookup); a public
            // handle equal to it would hand out half of a sign-in.
            && handle != username.lowercased()
    }

    // MARK: - Reading

    func threads(viewer: Viewer, cursor: String?, limit: Int) async throws -> CommunityPostPageDTO {
        let size = Self.pageSize(limit)
        var query: SQLQueryString = """
        \(unsafeRaw: Self.postProjection)
        WHERE p.parent_id IS NULL AND \(visibleTo(viewer))
        """
        if let cursor {
            let c = try Self.decodeCursor(cursor)
            query += " AND (p.last_activity_at, p.id) < (\(Self.timestamp(c.micros)), \(bind: c.id))"
        }
        query += " ORDER BY p.last_activity_at DESC, p.id DESC LIMIT \(bind: size + 1)"
        let rows = try await sql().raw(query).all(decoding: PostRow.self)
        return page(rows, size: size, viewer: viewer, cursorMicros: \.activity_us)
    }

    func replies(viewer: Viewer, parentID: UUID, cursor: String?, limit: Int) async throws -> CommunityPostPageDTO {
        _ = try await post(viewer: viewer, id: parentID)
        let size = Self.pageSize(limit)
        var query: SQLQueryString = """
        \(unsafeRaw: Self.postProjection)
        WHERE p.parent_id = \(bind: parentID) AND \(visibleTo(viewer))
        """
        if let cursor {
            let c = try Self.decodeCursor(cursor)
            query += " AND (p.created_at, p.id) > (\(Self.timestamp(c.micros)), \(bind: c.id))"
        }
        query += " ORDER BY p.created_at ASC, p.id ASC LIMIT \(bind: size + 1)"
        let rows = try await sql().raw(query).all(decoding: PostRow.self)
        return page(rows, size: size, viewer: viewer, cursorMicros: \.created_us)
    }

    func post(viewer: Viewer, id: UUID) async throws -> CommunityPostDTO {
        let row = try await sql().raw("""
        \(unsafeRaw: Self.postProjection)
        WHERE p.id = \(bind: id) AND \(visibleTo(viewer))
        """).first(decoding: PostRow.self)
        guard let row else { throw HTTPError(.notFound, message: ErrorCode.notFound.rawValue) }
        return Self.dto(row, viewer: viewer)
    }

    /// Today's (UTC) Daily Post, or nil before it is published.
    func todayDaily(viewer: Viewer, now: Date = Date()) async throws -> CommunityPostDTO? {
        let row = try await sql().raw("""
        \(unsafeRaw: Self.postProjection)
        JOIN community_daily_posts d ON d.post_id = p.id
        WHERE d.day = \(bind: DailyPostWorker.utcDay(now))::date AND d.status = 'published'
          AND \(visibleTo(viewer))
        """).first(decoding: PostRow.self)
        return row.map { Self.dto($0, viewer: viewer) }
    }

    // MARK: - Writing

    func createThread(userID: UUID, request: CommunityPostCreateRequest) async throws -> CommunityPostDTO {
        let title = request.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = request.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (3 ... 120).contains(title.count) else {
            throw HTTPError(.unprocessableContent, message: ErrorCode.invalidTitle.rawValue)
        }
        try Self.validateBody(body)
        let author = try await requirePoster(userID: userID)
        try await enforceDailyCap(profileID: author.id, replies: false)
        let status = try await moderate(title: title, body: body)
        let id = UUID()
        let now = Date()
        try await sql().raw("""
        INSERT INTO community_posts
            (id, parent_id, author_kind, author_profile_id, title, body, status,
             moderated_at, last_activity_at, created_at, updated_at)
        VALUES (\(bind: id), NULL, 'user', \(bind: author.id), \(bind: title), \(bind: body),
                \(bind: status), \(bind: status == "visible" ? now : nil), \(bind: now), \(bind: now), \(bind: now))
        """).run()
        return try await post(viewer: Viewer(userID: userID, profileID: author.id), id: id)
    }

    func createReply(userID: UUID, parentID: UUID, request: CommunityReplyCreateRequest) async throws -> CommunityPostDTO {
        let body = request.body.trimmingCharacters(in: .whitespacesAndNewlines)
        try Self.validateBody(body)
        let author = try await requirePoster(userID: userID)
        let viewer = Viewer(userID: userID, profileID: author.id)
        let parent = try await post(viewer: viewer, id: parentID)
        // One level of replies, and only under a thread that is on the board.
        guard parent.parentId == nil, parent.status == .visible else {
            throw HTTPError(.notFound, message: ErrorCode.notFound.rawValue)
        }
        try await enforceDailyCap(profileID: author.id, replies: true)
        let status = try await moderate(title: nil, body: body)
        let id = UUID()
        let now = Date()
        try await sql().raw("""
        INSERT INTO community_posts
            (id, parent_id, author_kind, author_profile_id, title, body, status,
             moderated_at, last_activity_at, created_at, updated_at)
        VALUES (\(bind: id), \(bind: parentID), 'user', \(bind: author.id), NULL, \(bind: body),
                \(bind: status), \(bind: status == "visible" ? now : nil), \(bind: now), \(bind: now), \(bind: now))
        """).run()
        if status == "visible" {
            try await refreshThread(parentID, touchedAt: now)
        }
        return try await post(viewer: viewer, id: id)
    }

    /// Author-only soft delete. The row stays so reports keep their target.
    func deletePost(userID: UUID, id: UUID) async throws {
        guard let profile = try await profile(userID: userID) else {
            throw HTTPError(.notFound, message: ErrorCode.notFound.rawValue)
        }
        let parent = try await sql().raw("""
        UPDATE community_posts
        SET status = 'deleted', body = '[deleted]', updated_at = now()
        WHERE id = \(bind: id) AND author_profile_id = \(bind: profile.id) AND status <> 'deleted'
        RETURNING parent_id
        """).first(decoding: ParentRow.self)
        guard let parent else { throw HTTPError(.notFound, message: ErrorCode.notFound.rawValue) }
        if let parentID = parent.parent_id {
            try await refreshThread(parentID, touchedAt: nil)
        }
    }

    /// Files a report. The `autoHideReportThreshold`-th distinct open report
    /// takes the post off the board until a moderator rules on it.
    func report(userID: UUID, postID: UUID, request: CommunityReportRequest) async throws {
        let reporter = try await requireProfile(userID: userID)
        let target = try await post(viewer: Viewer(userID: userID, profileID: reporter.id), id: postID)
        guard !target.isOwn else {
            throw HTTPError(.badRequest, message: ErrorCode.cannotReportOwn.rawValue)
        }
        let note = request.note.map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500)) }
        let sql = try sql()
        try await sql.raw("""
        INSERT INTO community_reports (id, post_id, reporter_profile_id, reason, note)
        VALUES (\(bind: UUID()), \(bind: postID), \(bind: reporter.id), \(bind: request.reason.rawValue),
                \(bind: note?.isEmpty == true ? nil : note))
        ON CONFLICT (post_id, reporter_profile_id) DO NOTHING
        """).run()
        let hidden = try await sql.raw("""
        UPDATE community_posts
        SET status = 'hidden', hidden_reason = 'reports', updated_at = now()
        WHERE id = \(bind: postID) AND status = 'visible'
          AND (SELECT count(*) FROM community_reports r
               WHERE r.post_id = \(bind: postID) AND r.status = 'open') >= \(bind: CommunityConfig.autoHideReportThreshold)
        RETURNING parent_id
        """).first(decoding: ParentRow.self)
        if let parentID = hidden?.parent_id {
            try await refreshThread(parentID, touchedAt: nil)
        }
        if hidden != nil {
            logger.notice("community.report auto-hid post=\(postID)")
        }
    }

    // MARK: - Blocks

    func blocks(userID: UUID) async throws -> CommunityBlockListDTO {
        guard let me = try await profile(userID: userID) else { return CommunityBlockListDTO(items: []) }
        let rows = try await sql().raw("""
        SELECT b.blocked_profile_id, pr.handle, pr.display_name, b.created_at
        FROM community_blocks b JOIN community_profiles pr ON pr.id = b.blocked_profile_id
        WHERE b.blocker_profile_id = \(bind: me.id)
        ORDER BY b.created_at DESC
        """).all(decoding: BlockRow.self)
        return CommunityBlockListDTO(items: rows.map {
            CommunityBlockedProfileDTO(
                profileId: $0.blocked_profile_id, handle: $0.handle,
                displayName: $0.display_name, blockedAt: $0.created_at
            )
        })
    }

    func block(userID: UUID, profileID: UUID) async throws {
        let me = try await requireProfile(userID: userID)
        guard me.id != profileID else {
            throw HTTPError(.badRequest, message: ErrorCode.cannotBlockSelf.rawValue)
        }
        let sql = try sql()
        guard try await sql.raw("SELECT 1 AS hit FROM community_profiles WHERE id = \(bind: profileID)").first() != nil else {
            throw HTTPError(.notFound, message: "profile_not_found")
        }
        try await sql.raw("""
        INSERT INTO community_blocks (blocker_profile_id, blocked_profile_id)
        VALUES (\(bind: me.id), \(bind: profileID))
        ON CONFLICT DO NOTHING
        """).run()
    }

    func unblock(userID: UUID, profileID: UUID) async throws {
        guard let me = try await profile(userID: userID) else { return }
        try await sql().raw("""
        DELETE FROM community_blocks
        WHERE blocker_profile_id = \(bind: me.id) AND blocked_profile_id = \(bind: profileID)
        """).run()
    }

    // MARK: - Moderators (`User.isAdmin`)

    enum QueueFilter: String {
        case all
        case open
        case pending
        case hidden
    }

    func adminQueue(filter: QueueFilter) async throws -> CommunityAdminQueueDTO {
        let condition = switch filter {
        case .all: "(p.status IN ('pending', 'hidden') OR EXISTS (SELECT 1 FROM community_reports r WHERE r.post_id = p.id AND r.status = 'open'))"
        case .open: "EXISTS (SELECT 1 FROM community_reports r WHERE r.post_id = p.id AND r.status = 'open')"
        case .pending: "p.status = 'pending'"
        case .hidden: "p.status = 'hidden'"
        }
        let rows = try await sql().raw("""
        SELECT q.*, p2.moderation_category, p2.hidden_reason,
               (SELECT count(*) FROM community_reports r WHERE r.post_id = q.id AND r.status = 'open') AS open_reports,
               (SELECT coalesce(array_agg(DISTINCT r.reason), '{}') FROM community_reports r
                WHERE r.post_id = q.id AND r.status = 'open') AS report_reasons,
               (SELECT max(r.created_at) FROM community_reports r WHERE r.post_id = q.id) AS latest_report_at
        FROM (\(unsafeRaw: Self.postProjection) WHERE \(unsafeRaw: condition)) q
        JOIN community_posts p2 ON p2.id = q.id
        ORDER BY latest_report_at DESC NULLS LAST, q.created_at DESC
        LIMIT 200
        """).all(decoding: QueueRow.self)
        let moderator = Viewer(userID: UUID(), profileID: nil)
        return CommunityAdminQueueDTO(items: rows.map { row in
            CommunityAdminQueueItemDTO(
                post: Self.dto(row.post, viewer: moderator),
                moderationCategory: row.moderation_category,
                hiddenReason: row.hidden_reason,
                openReports: row.open_reports,
                reportReasons: row.report_reasons.compactMap(CommunityReportReason.init(rawValue:)),
                latestReportAt: row.latest_report_at
            )
        })
    }

    func decide(adminUserID: UUID, postID: UUID, request: CommunityAdminDecisionRequest) async throws {
        let (status, body, reportStatus): (String, String?, String) = switch request.action {
        case .hide: ("hidden", nil, "actioned")
        case .restore: ("visible", nil, "dismissed")
        case .remove: ("deleted", "[removed by a moderator]", "actioned")
        }
        let reason = request.reason.map { String($0.prefix(500)) }
        let sql = try sql()
        let updated = try await sql.raw("""
        UPDATE community_posts
        SET status = \(bind: status),
            body = coalesce(\(bind: body), body),
            hidden_reason = \(bind: request.action == .restore ? nil : (reason ?? "moderator")),
            moderated_at = now(), updated_at = now()
        WHERE id = \(bind: postID)
        RETURNING parent_id
        """).first(decoding: ParentRow.self)
        guard let updated else { throw HTTPError(.notFound, message: ErrorCode.notFound.rawValue) }
        try await sql.raw("""
        UPDATE community_reports
        SET status = \(bind: reportStatus), resolved_at = now(), resolved_by_user_id = \(bind: adminUserID)
        WHERE post_id = \(bind: postID) AND status = 'open'
        """).run()
        if let parentID = updated.parent_id {
            try await refreshThread(parentID, touchedAt: nil)
        }
        logger.notice("community.moderation decision=\(request.action.rawValue) post=\(postID) by=\(adminUserID)")
    }

    func suspend(profileID: UUID, until: Date?) async throws {
        let row = try await sql().raw("""
        UPDATE community_profiles SET posting_suspended_until = \(bind: until), updated_at = now()
        WHERE id = \(bind: profileID) RETURNING id
        """).first()
        guard row != nil else { throw HTTPError(.notFound, message: "profile_not_found") }
    }

    // MARK: - Moderation sweep (driven by DailyPostWorker's tick)

    /// Re-checks posts held `pending` because the model was unavailable. After
    /// `maxAttempts` they stay pending for a human in the moderator queue.
    @discardableResult
    func recheckPending(olderThan age: TimeInterval = 300, maxAttempts: Int = 3, limit: Int = 20, now: Date = Date()) async throws -> Int {
        let sql = try sql()
        let rows = try await sql.raw("""
        SELECT id, parent_id, title, body FROM community_posts
        WHERE status = 'pending' AND moderation_attempts < \(bind: maxAttempts)
          AND created_at < \(bind: now.addingTimeInterval(-age))
        ORDER BY created_at LIMIT \(bind: limit)
        """).all(decoding: PendingRow.self)
        var resolved = 0
        for row in rows {
            switch await moderator.review(title: row.title, body: row.body) {
            case .allowed:
                try await sql.raw("""
                UPDATE community_posts SET status = 'visible', moderated_at = now(), updated_at = now(),
                    last_activity_at = now(), moderation_attempts = moderation_attempts + 1
                WHERE id = \(bind: row.id) AND status = 'pending'
                """).run()
                if let parentID = row.parent_id {
                    try await refreshThread(parentID, touchedAt: now)
                }
                resolved += 1
            case let .rejected(category):
                try await sql.raw("""
                UPDATE community_posts SET status = 'rejected', moderation_category = \(bind: category),
                    moderated_at = now(), updated_at = now(), moderation_attempts = moderation_attempts + 1
                WHERE id = \(bind: row.id) AND status = 'pending'
                """).run()
                resolved += 1
            case .unavailable:
                try await sql.raw("""
                UPDATE community_posts SET moderation_attempts = moderation_attempts + 1, updated_at = now()
                WHERE id = \(bind: row.id)
                """).run()
            }
        }
        return resolved
    }

    // MARK: - Internals

    struct ProfileRow: Decodable {
        let id: UUID
        let handle: String
        let display_name: String
        let terms_version: Int
        let terms_accepted_at: Date
        let posting_suspended_until: Date?
    }

    struct PostRow: Decodable {
        let id: UUID
        let parent_id: UUID?
        let title: String?
        let body: String
        let author_kind: String
        let author_profile_id: UUID?
        let handle: String?
        let display_name: String?
        let status: String
        let reply_count: Int
        let reaction_count: Int
        let created_at: Date
        let last_activity_at: Date
        let is_daily: Bool
        let activity_us: Int64
        let created_us: Int64
    }

    private struct QueueRow: Decodable {
        let post: PostRow
        let moderation_category: String?
        let hidden_reason: String?
        let open_reports: Int
        let report_reasons: [String]
        let latest_report_at: Date?

        init(from decoder: any Decoder) throws {
            post = try PostRow(from: decoder)
            let c = try decoder.container(keyedBy: Keys.self)
            moderation_category = try c.decodeIfPresent(String.self, forKey: .moderation_category)
            hidden_reason = try c.decodeIfPresent(String.self, forKey: .hidden_reason)
            open_reports = try c.decode(Int.self, forKey: .open_reports)
            report_reasons = try c.decodeIfPresent([String].self, forKey: .report_reasons) ?? []
            latest_report_at = try c.decodeIfPresent(Date.self, forKey: .latest_report_at)
        }

        enum Keys: String, CodingKey {
            case moderation_category, hidden_reason, open_reports, report_reasons, latest_report_at
        }
    }

    private struct ParentRow: Decodable { let parent_id: UUID? }
    private struct PendingRow: Decodable {
        let id: UUID
        let parent_id: UUID?
        let title: String?
        let body: String
    }

    private struct BlockRow: Decodable {
        let blocked_profile_id: UUID
        let handle: String
        let display_name: String
        let created_at: Date
    }

    private struct CountRow: Decodable { let n: Int }

    /// The only shape a post leaves the server in. Selects the profile's
    /// handle + display name and nothing from `users`.
    static let postProjection = """
    SELECT p.id, p.parent_id, p.title, p.body, p.author_kind, p.author_profile_id,
           pr.handle, pr.display_name, p.status, p.reply_count, p.reaction_count,
           p.created_at, p.last_activity_at,
           EXISTS (SELECT 1 FROM community_daily_posts d WHERE d.post_id = p.id) AS is_daily,
           (extract(epoch FROM p.last_activity_at) * 1000000)::bigint AS activity_us,
           (extract(epoch FROM p.created_at) * 1000000)::bigint AS created_us
    FROM community_posts p
    LEFT JOIN community_profiles pr ON pr.id = p.author_profile_id
    """

    /// Visible posts, plus the viewer's own pending ones; never anything by
    /// someone the viewer blocked.
    private func visibleTo(_ viewer: Viewer) -> SQLQueryString {
        guard let me = viewer.profileID else {
            return "p.status = 'visible'"
        }
        return """
        (p.status = 'visible' OR (p.status = 'pending' AND p.author_profile_id = \(bind: me)))
        AND NOT EXISTS (
            SELECT 1 FROM community_blocks b
            WHERE b.blocker_profile_id = \(bind: me) AND b.blocked_profile_id = p.author_profile_id
        )
        """
    }

    static func dto(_ row: PostRow, viewer: Viewer) -> CommunityPostDTO {
        let kind = CommunityAuthorKind(rawValue: row.author_kind) ?? .unknown
        let isOwn = viewer.profileID != nil && row.author_profile_id == viewer.profileID
        return CommunityPostDTO(
            id: row.id,
            parentId: row.parent_id,
            title: row.title,
            body: row.body,
            author: CommunityAuthorDTO(
                kind: kind, profileId: row.author_profile_id,
                handle: row.handle, displayName: row.display_name
            ),
            isDailyPost: row.is_daily,
            aiLabel: kind == .ai ? CommunityConfig.aiLabel : nil,
            status: CommunityPostStatus(rawValue: row.status) ?? .unknown,
            replyCount: row.reply_count,
            reactionCount: row.reaction_count,
            viewerReacted: false,
            isOwn: isOwn,
            createdAt: row.created_at,
            lastActivityAt: row.last_activity_at
        )
    }

    static func profileDTO(_ row: ProfileRow) -> CommunityProfileDTO {
        CommunityProfileDTO(
            id: row.id, handle: row.handle, displayName: row.display_name,
            termsVersion: row.terms_version, termsAcceptedAt: row.terms_accepted_at,
            postingSuspendedUntil: row.posting_suspended_until
        )
    }

    private func page(
        _ rows: [PostRow], size: Int, viewer: Viewer, cursorMicros: KeyPath<PostRow, Int64>
    ) -> CommunityPostPageDTO {
        let items = Array(rows.prefix(size))
        let next = rows.count > size ? items.last.map { Self.encodeCursor(micros: $0[keyPath: cursorMicros], id: $0.id) } : nil
        return CommunityPostPageDTO(items: items.map { Self.dto($0, viewer: viewer) }, nextCursor: next)
    }

    func profile(userID: UUID) async throws -> ProfileRow? {
        try await sql().raw("""
        SELECT id, handle, display_name, terms_version, terms_accepted_at, posting_suspended_until
        FROM community_profiles WHERE user_id = \(bind: userID)
        """).first(decoding: ProfileRow.self)
    }

    private func requireProfile(userID: UUID) async throws -> ProfileRow {
        guard let profile = try await profile(userID: userID) else {
            throw HTTPError(.forbidden, message: ErrorCode.profileRequired.rawValue)
        }
        return profile
    }

    /// A member who may post right now: profile, current terms, not suspended,
    /// and posting switched on.
    private func requirePoster(userID: UUID, now: Date = Date()) async throws -> ProfileRow {
        guard config.postingEnabled else {
            throw HTTPError(.serviceUnavailable, message: ErrorCode.postingDisabled.rawValue)
        }
        let profile = try await requireProfile(userID: userID)
        guard profile.terms_version >= CommunityConfig.termsVersion else {
            throw HTTPError(.forbidden, message: ErrorCode.termsRequired.rawValue)
        }
        if let until = profile.posting_suspended_until, until > now {
            throw HTTPError(.forbidden, message: ErrorCode.postingSuspended.rawValue)
        }
        return profile
    }

    private func enforceDailyCap(profileID: UUID, replies: Bool) async throws {
        let cap = replies ? CommunityConfig.maxRepliesPerDay : CommunityConfig.maxThreadsPerDay
        let row = try await sql().raw("""
        SELECT count(*)::int AS n FROM community_posts
        WHERE author_profile_id = \(bind: profileID)
          AND (parent_id IS NOT NULL) = \(bind: replies)
          AND created_at > now() - interval '24 hours'
        """).first(decoding: CountRow.self)
        if (row?.n ?? 0) >= cap {
            throw HTTPError(.tooManyRequests, message: ErrorCode.dailyLimit.rawValue)
        }
    }

    /// `visible` or `pending`; throws 422 on a rejection.
    private func moderate(title: String?, body: String) async throws -> String {
        switch await moderator.review(title: title, body: body) {
        case .allowed:
            return "visible"
        case .unavailable:
            return "pending"
        case let .rejected(category):
            logger.info("community.moderation rejected category=\(category)")
            throw HTTPError(.unprocessableContent, message: "\(ErrorCode.rejected.rawValue):\(category)")
        }
    }

    /// Recounts a thread's visible replies; `touchedAt` also bumps it to the
    /// top of the board.
    private func refreshThread(_ id: UUID, touchedAt: Date?) async throws {
        try await sql().raw("""
        UPDATE community_posts SET
            reply_count = (SELECT count(*) FROM community_posts c
                           WHERE c.parent_id = \(bind: id) AND c.status = 'visible'),
            last_activity_at = greatest(last_activity_at, coalesce(\(bind: touchedAt), last_activity_at))
        WHERE id = \(bind: id)
        """).run()
    }

    static func validateBody(_ body: String) throws {
        guard (1 ... 4000).contains(body.count) else {
            throw HTTPError(.unprocessableContent, message: ErrorCode.invalidBody.rawValue)
        }
    }

    static func pageSize(_ limit: Int) -> Int {
        min(max(limit, 1), maxPageSize)
    }

    // Cursor: base64url("<epoch microseconds>|<uuid>"). Microseconds keep
    // the comparison exact against Postgres timestamps.
    static func encodeCursor(micros: Int64, id: UUID) -> String {
        Data("\(micros)|\(id.uuidString)".utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decodeCursor(_ cursor: String) throws -> (micros: Int64, id: UUID) {
        var b64 = cursor.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 {
            b64 += "="
        }
        guard let data = Data(base64Encoded: b64), let text = String(data: data, encoding: .utf8) else {
            throw HTTPError(.badRequest, message: ErrorCode.invalidCursor.rawValue)
        }
        let parts = text.split(separator: "|")
        guard parts.count == 2, let micros = Int64(parts[0]), let id = UUID(uuidString: String(parts[1])) else {
            throw HTTPError(.badRequest, message: ErrorCode.invalidCursor.rawValue)
        }
        return (micros, id)
    }

    private static func timestamp(_ micros: Int64) -> SQLQueryString {
        "(TIMESTAMPTZ 'epoch' + \(bind: micros) * INTERVAL '1 microsecond')"
    }

    private func sql() throws -> any SQLDatabase {
        guard let sql = fluent.db() as? any SQLDatabase else {
            throw HTTPError(.internalServerError, message: "sql unavailable")
        }
        return sql
    }
}
