import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import Logging
import LuminaVaultShared

extension ReminderListResponse: @retroactive ResponseEncodable {}
extension ReminderDTO: @retroactive ResponseEncodable {}
extension ReminderProposalDTO: @retroactive ResponseEncodable {}

/// HER-Reminders — CRUD for user-scheduled timed messages.
///
/// Endpoints (all tenant-scoped via `jwtAuthenticator`):
/// - `GET    /v1/reminders` — pending + fired, newest `fireAt` first.
/// - `POST   /v1/reminders` — create.
/// - `POST   /v1/reminders/detect` — HER-55 classify a chat turn → proposal.
/// - `PATCH  /v1/reminders/:id` — edit title/body/fireAt/recurrence.
/// - `DELETE /v1/reminders/:id` — remove.
///
/// Firing is owned by `ReminderScheduler`, not this controller.
struct RemindersController {
    let fluent: Fluent
    /// HER-55 — chat→reminder classifier. Optional so non-chat deployments
    /// (and tests) can construct the controller without an LLM transport;
    /// when nil, `/detect` always returns `isReminder: false`.
    let classifier: ReminderIntentClassifier?
    let logger: Logger

    private static let maxLimit = 200
    private static let defaultLimit = 100

    init(fluent: Fluent, classifier: ReminderIntentClassifier? = nil, logger: Logger) {
        self.fluent = fluent
        self.classifier = classifier
        self.logger = logger
    }

    func addRoutes(to router: RouterGroup<AppRequestContext>) {
        router.get("", use: list)
        router.post("", use: create)
        router.post("/detect", use: detect)
        router.patch(":id", use: update)
        router.delete(":id", use: delete)
    }

    struct DetectRequest: Decodable { let text: String }

    /// HER-55 — classify a chat message for reminder intent. Never creates
    /// anything; the client surfaces the proposal and calls `create` on
    /// confirm. Fails closed (`isReminder: false`) when the classifier is
    /// absent so chat is never blocked.
    @Sendable
    func detect(_ req: Request, ctx: AppRequestContext) async throws -> ReminderProposalDTO {
        let tenantID = try ctx.requireTenantID()
        guard let classifier else { return ReminderProposalDTO(isReminder: false) }
        let body = try await req.decode(as: DetectRequest.self, context: ctx)
        return await classifier.classify(text: body.text, tenantID: tenantID)
    }

    @Sendable
    func list(_ req: Request, ctx: AppRequestContext) async throws -> ReminderListResponse {
        let tenantID = try ctx.requireTenantID()
        let limit = Self.parseLimit(req)
        let rows = try await Reminder.query(on: fluent.db(), tenantID: tenantID)
            .sort(\.$fireAt, .descending)
            .limit(limit)
            .all()
        return try ReminderListResponse(reminders: rows.map { try $0.toDTO() }, nextCursor: nil)
    }

    @Sendable
    func create(_ req: Request, ctx: AppRequestContext) async throws -> ReminderDTO {
        let tenantID = try ctx.requireTenantID()
        let body = try await req.decode(as: ReminderCreateRequest.self, context: ctx)
        let title = body.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            throw HTTPError(.badRequest, message: "reminder title required")
        }
        try Self.validateCron(body.recurrenceCron)
        let reminder = Reminder(
            tenantID: tenantID,
            title: title,
            body: body.body,
            fireAt: body.fireAt,
            recurrenceCron: body.recurrenceCron
        )
        try await reminder.save(on: fluent.db())
        return try reminder.toDTO()
    }

    @Sendable
    func update(_ req: Request, ctx: AppRequestContext) async throws -> ReminderDTO {
        let tenantID = try ctx.requireTenantID()
        let id = try Self.parseID(ctx)
        let body = try await req.decode(as: ReminderPatchRequest.self, context: ctx)
        guard let reminder = try await Reminder.query(on: fluent.db(), tenantID: tenantID)
            .filter(\.$id == id)
            .first()
        else { throw HTTPError(.notFound, message: "reminder not found") }

        if let title = body.title {
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw HTTPError(.badRequest, message: "reminder title cannot be empty")
            }
            reminder.title = trimmed
        }
        if let bodyText = body.body { reminder.body = bodyText }
        if let fireAt = body.fireAt {
            reminder.fireAt = fireAt
            // Editing the fire time re-arms a fired reminder.
            reminder.firedAt = nil
        }
        if let cron = body.recurrenceCron {
            try Self.validateCron(cron)
            reminder.recurrenceCron = cron.isEmpty ? nil : cron
        }
        try await reminder.save(on: fluent.db())
        return try reminder.toDTO()
    }

    @Sendable
    func delete(_: Request, ctx: AppRequestContext) async throws -> Response {
        let tenantID = try ctx.requireTenantID()
        let id = try Self.parseID(ctx)
        guard let reminder = try await Reminder.query(on: fluent.db(), tenantID: tenantID)
            .filter(\.$id == id)
            .first()
        else { throw HTTPError(.notFound, message: "reminder not found") }
        try await reminder.delete(on: fluent.db())
        return Response(status: .noContent)
    }

    // MARK: - Helpers

    private static func validateCron(_ cron: String?) throws {
        guard let cron, !cron.isEmpty else { return }
        guard (try? CronExpression(cron)) != nil else {
            throw HTTPError(.badRequest, message: "invalid recurrence cron expression")
        }
    }

    private static func parseID(_ ctx: AppRequestContext) throws -> UUID {
        guard let raw = ctx.parameters.get("id"), let id = UUID(uuidString: raw) else {
            throw HTTPError(.badRequest, message: "invalid reminder id")
        }
        return id
    }

    private static func parseLimit(_ req: Request) -> Int {
        guard let raw = req.uri.queryParameters["limit"].flatMap({ Int(String($0)) }) else {
            return defaultLimit
        }
        return max(1, min(raw, maxLimit))
    }
}
