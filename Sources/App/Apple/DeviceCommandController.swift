import Foundation
import Hummingbird
import Logging
import LuminaVaultShared

/// Apple Integration P0b — the app posts a device command's result here, which
/// resolves the broker's pending request (completing the Hermes tool call).
///   POST /v1/devices/command/{id}/result
struct DeviceCommandController {
    let broker: DeviceCommandBroker
    let queue: DeviceCommandQueue
    let logger: Logger

    func addRoutes(to router: RouterGroup<AppRequestContext>) {
        router.post("/command/:id/result", use: result)
        router.get("/commands/pending", use: pending)
    }

    @Sendable
    func result(_ req: Request, ctx: AppRequestContext) async throws -> HTTPResponse.Status {
        let tenantID = try ctx.requireTenantID()
        let body = try await req.decode(as: DeviceCommandResult.self, context: ctx)
        await broker.resolve(body)
        // A queued command (or its live twin arriving late) is done either way.
        try await queue.markDelivered(tenantID: tenantID, result: body)
        return .ok
    }

    /// `GET /v1/devices/commands/pending` — phone writes queued while the app
    /// was closed, oldest first. The app runs each and posts its result above.
    @Sendable
    func pending(_: Request, ctx: AppRequestContext) async throws -> PendingDeviceCommandsResponse {
        let tenantID = try ctx.requireTenantID()
        return try await PendingDeviceCommandsResponse(commands: queue.pending(tenantID: tenantID))
    }
}

extension PendingDeviceCommandsResponse: @retroactive ResponseEncodable {}
