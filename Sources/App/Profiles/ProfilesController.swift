import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import Logging
import LuminaVaultShared

extension HermesProfileDTO: ResponseEncodable {}
extension HermesProfilesListResponse: ResponseEncodable {}
extension HermesProfileActivateResponse: ResponseEncodable {}

/// HER-273 — `/v1/profiles` CRUD + activate for user-facing Hermes
/// personas. Per-tenant: one row per `slug`, exactly one default
/// (partial unique index in `M51`). Activation flips the default
/// flag atomically inside a Fluent transaction; the chat path reads
/// the active slug via the `HermesProfileMiddleware`, falling back
/// to the default row when the request omits `X-Hermes-Profile`.
///
/// Slug constraints: 1–32 chars, lowercase letters / digits / hyphen.
/// Label: 1–80 chars. System prompt: 0–8 KB.
struct ProfilesController {
    enum ErrorCode: String {
        case invalidSlug = "invalid_slug"
        case invalidLabel = "invalid_label"
        case systemPromptTooLong = "system_prompt_too_long"
        case slugAlreadyExists = "slug_already_exists"
        case profileNotFound = "profile_not_found"
        case cannotDeleteDefault = "cannot_delete_default"
        case templateNotFound = "template_not_found"
    }

    static let maxSystemPromptBytes = 8 * 1024
    static let slugPattern = #"^[a-z0-9][a-z0-9-]{0,31}$"#

    let fluent: Fluent
    let logger: Logger

    func addRoutes(to router: RouterGroup<AppRequestContext>) {
        router.get(use: list)
        router.post(use: create)
        router.get(":slug", use: getOne)
        router.patch(":slug", use: patch)
        router.delete(":slug", use: delete)
        router.post(":slug/activate", use: activate)
    }

    // MARK: - GET /v1/profiles

    @Sendable
    func list(_: Request, ctx: AppRequestContext) async throws -> HermesProfilesListResponse {
        let tenantID = try ctx.requireTenantID()
        let rows = try await UserHermesProfile.query(on: fluent.db(), tenantID: tenantID)
            .sort(\.$createdAt, .ascending)
            .all()
        let items = rows.map(Self.toDTO(_:))
        let activeSlug = rows.first(where: { $0.isDefault })?.slug
        return HermesProfilesListResponse(items: items, activeSlug: activeSlug)
    }

    // MARK: - POST /v1/profiles

    @Sendable
    func create(_ req: Request, ctx: AppRequestContext) async throws -> HermesProfileDTO {
        let tenantID = try ctx.requireTenantID()
        let body = try await req.decode(as: HermesProfileCreateRequest.self, context: ctx)

        try Self.validateSlug(body.slug)
        try Self.validateLabel(body.label)

        let systemPrompt = try Self.resolveSystemPrompt(
            explicit: body.systemPrompt,
            templateSlug: body.templateSlug,
        )

        let duplicate = try await UserHermesProfile.query(on: fluent.db(), tenantID: tenantID)
            .filter(\.$slug == body.slug)
            .first()
        if duplicate != nil {
            throw HTTPError(.conflict, message: ErrorCode.slugAlreadyExists.rawValue)
        }

        // First profile becomes default automatically. Otherwise the
        // user must call POST /:slug/activate.
        let hasAnyProfile = try await UserHermesProfile.query(on: fluent.db(), tenantID: tenantID)
            .count() > 0

        let row = UserHermesProfile(
            tenantID: tenantID,
            slug: body.slug,
            label: body.label,
            systemPrompt: systemPrompt,
            isDefault: !hasAnyProfile,
            skillsEnabled: body.skillsEnabled ?? [],
        )
        try await row.save(on: fluent.db())
        return Self.toDTO(row)
    }

    // MARK: - GET /v1/profiles/{slug}

    @Sendable
    func getOne(_: Request, ctx: AppRequestContext) async throws -> HermesProfileDTO {
        let slug = try Self.requireSlugParam(ctx)
        let row = try await loadRow(ctx: ctx, slug: slug)
        return Self.toDTO(row)
    }

    // MARK: - PATCH /v1/profiles/{slug}

    @Sendable
    func patch(_ req: Request, ctx: AppRequestContext) async throws -> HermesProfileDTO {
        let slug = try Self.requireSlugParam(ctx)
        let body = try await req.decode(as: HermesProfilePatchRequest.self, context: ctx)
        let row = try await loadRow(ctx: ctx, slug: slug)

        if let label = body.label {
            try Self.validateLabel(label)
            row.label = label
        }
        if let prompt = body.systemPrompt {
            try Self.validateSystemPrompt(prompt)
            row.systemPrompt = prompt
        }
        if let skills = body.skillsEnabled {
            row.skillsEnabled = skills
        }
        try await row.save(on: fluent.db())
        return Self.toDTO(row)
    }

    // MARK: - DELETE /v1/profiles/{slug}

    @Sendable
    func delete(_: Request, ctx: AppRequestContext) async throws -> Response {
        let slug = try Self.requireSlugParam(ctx)
        let row = try await loadRow(ctx: ctx, slug: slug)
        if row.isDefault {
            throw HTTPError(.conflict, message: ErrorCode.cannotDeleteDefault.rawValue)
        }
        try await row.delete(on: fluent.db())
        return Response(status: .noContent)
    }

    // MARK: - POST /v1/profiles/{slug}/activate

    @Sendable
    func activate(_: Request, ctx: AppRequestContext) async throws -> HermesProfileActivateResponse {
        let tenantID = try ctx.requireTenantID()
        let slug = try Self.requireSlugParam(ctx)

        let activatedAt: Date = try await fluent.db().transaction { db in
            guard let target = try await UserHermesProfile.query(on: db, tenantID: tenantID)
                .filter(\.$slug == slug)
                .first()
            else {
                throw HTTPError(.notFound, message: ErrorCode.profileNotFound.rawValue)
            }
            if target.isDefault {
                return target.updatedAt ?? Date()
            }
            // Clear any other default. Partial unique index forbids two TRUE values.
            try await UserHermesProfile.query(on: db, tenantID: tenantID)
                .filter(\.$isDefault == true)
                .set(\.$isDefault, to: false)
                .update()
            target.isDefault = true
            try await target.save(on: db)
            return target.updatedAt ?? Date()
        }
        return HermesProfileActivateResponse(slug: slug, activatedAt: activatedAt)
    }

    // MARK: - Helpers

    private func loadRow(ctx: AppRequestContext, slug: String) async throws -> UserHermesProfile {
        let tenantID = try ctx.requireTenantID()
        guard let row = try await UserHermesProfile.query(on: fluent.db(), tenantID: tenantID)
            .filter(\.$slug == slug)
            .first()
        else {
            throw HTTPError(.notFound, message: ErrorCode.profileNotFound.rawValue)
        }
        return row
    }

    private static func requireSlugParam(_ ctx: AppRequestContext) throws -> String {
        try ctx.parameters.require("slug", as: String.self)
    }

    private static func validateSlug(_ slug: String) throws {
        guard slug.range(of: slugPattern, options: .regularExpression) != nil else {
            throw HTTPError(.badRequest, message: ErrorCode.invalidSlug.rawValue)
        }
    }

    private static func validateLabel(_ label: String) throws {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1 ... 80).contains(trimmed.count) else {
            throw HTTPError(.badRequest, message: ErrorCode.invalidLabel.rawValue)
        }
    }

    private static func validateSystemPrompt(_ prompt: String) throws {
        guard prompt.utf8.count <= maxSystemPromptBytes else {
            throw HTTPError(.badRequest, message: ErrorCode.systemPromptTooLong.rawValue)
        }
    }

    /// Resolve the persona's seed system prompt. `templateSlug` wins
    /// over `systemPrompt` so the iOS client can pick "stocks-tracker"
    /// without prefetching the body. HER-273-B5 ships the real catalog;
    /// for now we expose a small built-in fallback so B1 is usable
    /// before B5 lands.
    private static func resolveSystemPrompt(
        explicit: String?,
        templateSlug: String?,
    ) throws -> String {
        if let slug = templateSlug, !slug.isEmpty {
            guard let body = builtInTemplate(slug) else {
                throw HTTPError(.badRequest, message: ErrorCode.templateNotFound.rawValue)
            }
            try validateSystemPrompt(body)
            return body
        }
        let body = explicit ?? Self.defaultSeed
        try validateSystemPrompt(body)
        return body
    }

    private static let defaultSeed = """
    You are Hermes — a personal assistant. Tone: warm, concise.

    ## Behavior
    - ALWAYS save any link mentioned in chat to the user's vault. Confirm the save in your reply with the destination filename.
    """

    /// Minimal stand-in for HER-273-B5's `/v1/soul/templates`. Kept
    /// inline so B1 ships ahead of B5; B5 replaces this with a
    /// catalogued read from `SOULService`.
    private static func builtInTemplate(_ slug: String) -> String? {
        switch slug {
        case "personal-assistant": defaultSeed
        case "stocks-tracker":
            """
            You are Hermes, focused on equities and macro signals.

            ## Behavior
            - ALWAYS save any link mentioned in chat to the user's vault.
            - Lead with the ticker; quote 1-day, 5-day, YTD where relevant.
            """
        case "news-curator":
            """
            You are Hermes, a high-signal news curator.

            ## Behavior
            - ALWAYS save any link mentioned in chat to the user's vault.
            - Prefer primary sources; flag opinion vs reporting.
            """
        case "tv-and-movies":
            """
            You are Hermes, a personal screen recommender.

            ## Behavior
            - ALWAYS save any link mentioned in chat to the user's vault.
            - Track what the user watched; never re-recommend it.
            """
        case "tech-and-programming":
            """
            You are Hermes, a senior engineering pair.

            ## Behavior
            - ALWAYS save any link mentioned in chat to the user's vault.
            - Quote file:line when discussing repo code; cite the source library by version.
            """
        default: nil
        }
    }

    static func toDTO(_ row: UserHermesProfile) -> HermesProfileDTO {
        HermesProfileDTO(
            id: row.id ?? UUID(),
            slug: row.slug,
            label: row.label,
            systemPrompt: row.systemPrompt,
            isDefault: row.isDefault,
            skillsEnabled: row.skillsEnabled,
            createdAt: row.createdAt ?? Date(),
            updatedAt: row.updatedAt ?? Date(),
        )
    }
}
