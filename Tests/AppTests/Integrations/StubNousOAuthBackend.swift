@testable import App
import Foundation

/// Nous Subscription Integration — in-memory backend stub. Drives the
/// `NousOAuthService` start/complete/revoke flow without shelling out to a
/// Hermes container. Mirrors `StubXaiOAuthBackend`.
actor StubNousOAuthBackend: NousOAuthBackend {
    var verificationResult: Result<(verifyURL: String, userCode: String?), Error> =
        .success((verifyURL: "https://portal.nousresearch.com/device?user_code=STUB-CODE", userCode: "STUB-CODE"))
    var completionResult: Result<Bool, Error> = .success(true)
    var revokeResult: Result<Bool, Error> = .success(true)
    var planResult: String?
    private(set) var requestCalls: [String] = []
    private(set) var completeCalls: [String] = []
    private(set) var cancelCalls: [String] = []
    private(set) var revokeCalls: Int = 0

    func requestVerification(
        handle _: HermesContainerHandle,
        sessionID: String
    ) async throws -> (verifyURL: String, userCode: String?) {
        requestCalls.append(sessionID)
        return try verificationResult.get()
    }

    func awaitCompletion(
        handle _: HermesContainerHandle,
        sessionID: String
    ) async throws -> Bool {
        completeCalls.append(sessionID)
        return try completionResult.get()
    }

    func cancel(sessionID: String) async {
        cancelCalls.append(sessionID)
    }

    func revoke(handle _: HermesContainerHandle) async throws -> Bool {
        revokeCalls += 1
        return try revokeResult.get()
    }

    func subscriptionPlan(handle _: HermesContainerHandle) async -> String? {
        planResult
    }

    func setCompletionResult(_ value: Result<Bool, Error>) {
        completionResult = value
    }
}
