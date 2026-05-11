import Foundation
import Hummingbird
import HummingbirdFluent
import Logging

/// HER-197 scaffold — `/v1/settings/hermes` GET/PUT/DELETE/test.
///
/// JWT + `userOrIP` rate-limit (set up in `App+build.swift`). Every
/// PUT re-encrypts the auth header through `SecretBox` and resets
/// `verified_at`. `GET` reports only `{ baseUrl, hasAuthHeader,
/// verifiedAt }` — the cleartext header is never echoed. `DELETE`
/// drops the row. `POST .../test` issues a probe request to
/// `<baseUrl>/v1/models` (fallback `/healthz`) through the same
/// transport stack the real traffic uses; on 2xx it sets
/// `verified_at = NOW()`.
///
/// Real handlers in HER-197 follow-up. Scaffold returns 501 so the
/// route surface compiles + the iOS settings pane can wire its
/// requests against the real shape.
struct HermesConfigController {
    struct GetResponse: Codable, ResponseEncodable {
        let baseUrl: String
        let hasAuthHeader: Bool
        let verifiedAt: Date?
    }

    struct PutRequest: Codable {
        let baseUrl: String
        let authHeader: String?
    }

    struct TestResponse: Codable, ResponseEncodable {
        let verifiedAt: Date
    }

    let fluent: Fluent
    let secretBox: SecretBox
    let ssrfGuard: SSRFGuard
    let logger: Logger

    func addRoutes(to router: RouterGroup<AppRequestContext>) {
        router.get(use: get)
        router.put(use: put)
        router.delete(use: delete)
        router.post("test", use: test)
    }

    @Sendable
    func get(_: Request, ctx _: AppRequestContext) async throws -> GetResponse {
        throw HTTPError(.notImplemented, message: "HER-197 — HermesConfigController.get")
    }

    @Sendable
    func put(_: Request, ctx _: AppRequestContext) async throws -> GetResponse {
        throw HTTPError(.notImplemented, message: "HER-197 — HermesConfigController.put")
    }

    @Sendable
    func delete(_: Request, ctx _: AppRequestContext) async throws -> Response {
        throw HTTPError(.notImplemented, message: "HER-197 — HermesConfigController.delete")
    }

    @Sendable
    func test(_: Request, ctx _: AppRequestContext) async throws -> TestResponse {
        throw HTTPError(.notImplemented, message: "HER-197 — HermesConfigController.test")
    }
}
