@testable import App
import Foundation

/// HER-240a — in-memory backend stub. Lets tests drive the
/// `XaiOAuthService` start/complete/revoke flow without actually shelling
/// out to a Hermes container.
actor StubXaiOAuthBackend: XaiOAuthBackend {
    var authorizeURLResult: Result<String, Error> = .success("https://accounts.x.ai/authorize?stub=1")
    var submitCallbackResult: Result<Bool, Error> = .success(true)
    var revokeResult: Result<Bool, Error> = .success(true)
    private(set) var requestCalls: [String] = []
    private(set) var submitCalls: [(sessionID: String, callbackURL: String)] = []
    private(set) var cancelCalls: [String] = []
    private(set) var revokeCalls: Int = 0

    func requestAuthorizeURL(handle _: HermesContainerHandle, sessionID: String) async throws -> String {
        requestCalls.append(sessionID)
        return try authorizeURLResult.get()
    }

    func submitCallback(
        handle _: HermesContainerHandle,
        sessionID: String,
        callbackURL: String,
    ) async throws -> Bool {
        submitCalls.append((sessionID, callbackURL))
        return try submitCallbackResult.get()
    }

    func cancel(sessionID: String) async {
        cancelCalls.append(sessionID)
    }

    func revoke(handle _: HermesContainerHandle) async throws -> Bool {
        revokeCalls += 1
        return try revokeResult.get()
    }
}
