import FluentKit
import Foundation
import HummingbirdFluent
import Logging
import LuminaVaultShared

/// One phone write waiting for the app to open.
final class QueuedDeviceCommand: Model, TenantModel, @unchecked Sendable {
    static let schema = "device_command_queue"

    @ID(custom: "id", generatedBy: .user) var id: UUID?
    @Field(key: "tenant_id") var tenantID: UUID
    @Field(key: "kind") var kind: String
    @OptionalField(key: "domain") var domain: String?
    /// The command's `[String: String]` payload, as JSON.
    @Field(key: "payload") var payload: String
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Field(key: "expires_at") var expiresAt: Date
    @OptionalField(key: "delivered_at") var deliveredAt: Date?
    @OptionalField(key: "result_ok") var resultOK: Bool?
    @OptionalField(key: "result_error") var resultError: String?

    init() {}

    func asCommand() -> DeviceCommand? {
        guard let id, let kind = DeviceCommandKind(rawValue: kind) else { return nil }
        let args = (try? JSONDecoder().decode([String: String].self, from: Data(payload.utf8))) ?? [:]
        return DeviceCommand(id: id, kind: kind, domain: domain.flatMap(AppleDataDomain.init(rawValue:)), payload: args)
    }
}

/// Holds phone writes the app was not connected for, and tells the user.
///
/// A write that times out over the socket is stored here and announced with
/// a visible push ("Lumina wants to add … — open LuminaVault"): iOS throttles
/// silent pushes and never delivers them to a force-quit app, so a banner is
/// the reliable way to get the app open. On open, the app reads
/// `GET /v1/devices/commands/pending`, runs each command, and posts its result
/// to the existing result endpoint.
struct DeviceCommandQueue: Sendable {
    /// A write older than this is dropped rather than run a day late.
    static let lifetime: TimeInterval = 24 * 60 * 60
    /// Only writes queue; a read the phone missed is simply unavailable.
    static let queueable: Set<DeviceCommandKind> = [.reminderCreate, .calendarCreate]

    let fluent: Fluent
    let apns: APNSNotificationService?
    let logger: Logger

    func enqueue(tenantID: UUID, command: DeviceCommand) async throws {
        let row = QueuedDeviceCommand()
        row.id = command.id
        row.tenantID = tenantID
        row.kind = command.kind.rawValue
        row.domain = command.domain?.rawValue
        row.payload = try String(decoding: JSONEncoder().encode(command.payload), as: UTF8.self)
        row.expiresAt = Date().addingTimeInterval(Self.lifetime)
        try await row.save(on: fluent.db())
        logger.info("device.command queued tenant=\(tenantID) id=\(command.id) kind=\(command.kind.rawValue)")

        do {
            try await apns?.notify(
                userID: tenantID,
                title: "Lumina has something for your iPhone",
                subtitle: nil,
                body: Self.announcement(for: command),
                category: .deviceCommand,
                payload: ["deviceCommandID": command.id.uuidString],
            )
        } catch {
            // The command stays queued; the app picks it up whenever it opens.
            logger.warning("device.command push failed id=\(command.id): \(error)")
        }
    }

    /// Undelivered, unexpired commands, oldest first.
    func pending(tenantID: UUID) async throws -> [DeviceCommand] {
        try await QueuedDeviceCommand.query(on: fluent.db(), tenantID: tenantID)
            .filter(\.$deliveredAt == nil)
            .filter(\.$expiresAt > Date())
            .sort(\.$createdAt)
            .limit(50)
            .all()
            .compactMap { $0.asCommand() }
    }

    /// Records the result of a queued command. Only the owner's rows match,
    /// so another account's result can never mark this one delivered.
    func markDelivered(tenantID: UUID, result: DeviceCommandResult) async throws {
        guard let row = try await QueuedDeviceCommand.query(on: fluent.db(), tenantID: tenantID)
            .filter(\.$id == result.id)
            .filter(\.$deliveredAt == nil)
            .first()
        else { return }
        row.deliveredAt = Date()
        row.resultOK = result.ok
        row.resultError = result.error
        try await row.save(on: fluent.db())
    }

    static func announcement(for command: DeviceCommand) -> String {
        let title = command.payload["title"].flatMap { $0.isEmpty ? nil : $0 } ?? "an item"
        return switch command.kind {
        case .reminderCreate: "Open LuminaVault to add the reminder “\(title)”."
        case .calendarCreate: "Open LuminaVault to add “\(title)” to your calendar."
        default: "Open LuminaVault to finish a request from Lumina."
        }
    }
}
