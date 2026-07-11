import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
import Hummingbird
import Logging
import LuminaVaultShared

protocol PluginRunnerClienting: Sendable {
    func execute(module: Data, input: [String: String]) async throws -> (output: [String: String], fuelConsumed: Int)
}

struct PluginRunnerClient: PluginRunnerClienting {
    let baseURL: URL
    let token: String
    let logger: Logger

    func execute(module: Data, input: [String: String]) async throws -> (output: [String: String], fuelConsumed: Int) {
        guard !token.isEmpty else { throw HTTPError(.serviceUnavailable, message: "plugin_runner_disabled") }
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/execute"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 32
        request.httpBody = try JSONEncoder().encode(RunnerRequest(
            moduleBase64: module.base64EncodedString(), input: input, fuel: 10_000_000
        ))
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            logger.warning("plugin runner rejected execution", metadata: ["status": "\((response as? HTTPURLResponse)?.statusCode ?? 0)"])
            throw HTTPError(.badGateway, message: "plugin_runner_rejected")
        }
        let decoded = try JSONDecoder().decode(RunnerResponse.self, from: data)
        return (decoded.output, decoded.fuelConsumed)
    }

    private struct RunnerRequest: Encodable {
        let moduleBase64: String
        let input: [String: String]
        let fuel: Int
    }

    private struct RunnerResponse: Decodable {
        let output: [String: String]
        let fuelConsumed: Int
    }
}

struct DisabledPluginRunnerClient: PluginRunnerClienting {
    func execute(module _: Data, input _: [String: String]) async throws -> (output: [String: String], fuelConsumed: Int) {
        throw HTTPError(.serviceUnavailable, message: "plugin_runner_disabled")
    }
}
