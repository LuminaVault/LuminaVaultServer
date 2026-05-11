import AppAPI
import OpenAPIRuntime

struct APIImplementation: APIProtocol {
    func getHello(_: AppAPI.Operations.GetHello.Input) async throws -> AppAPI.Operations.GetHello.Output {
        .ok(.init(body: .plainText("Hello!")))
    }
}
