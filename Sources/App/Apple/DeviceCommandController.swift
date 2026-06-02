import Foundation
import Hummingbird
import Logging
import LuminaVaultShared

/// Apple Integration P0b — the app posts a device command's result here, which
/// resolves the broker's pending request (completing the Hermes tool call).
///   POST /v1/devices/command/{id}/result
struct DeviceCommandController {
    let broker: DeviceCommandBroker
    let logger: Logger

    func addRoutes(to router: RouterGroup<AppRequestContext>) {
        router.post("/command/:id/result", use: result)
    }

    @Sendable
    func result(_ req: Request, ctx: AppRequestContext) async throws -> HTTPResponse.Status {
        _ = try ctx.requireIdentity()
        let body = try await req.decode(as: DeviceCommandResult.self, context: ctx)
        await broker.resolve(body)
        return .ok
    }
}
