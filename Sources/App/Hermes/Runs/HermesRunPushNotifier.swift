import Foundation
import Logging
import LuminaVaultShared

/// Push side of a run: approval requests and completions. Seam so the
/// service tests assert calls without a device-token table.
protocol HermesRunPushNotifying: Sendable {
    func approvalRequested(tenantID: UUID, run: HermesRunDTO) async
    func runFinished(tenantID: UUID, run: HermesRunDTO) async
}

/// APNS delivery through `APNSNotificationService` (category prefs,
/// dead-token reaping and the enabled gate all apply). Never throws — a
/// failed push must not stop the watcher.
struct APNSHermesRunPushNotifier: HermesRunPushNotifying {
    let push: APNSNotificationService
    let logger: Logger

    static let approvalTitle = "Hermes needs approval"
    static let bodyLimit = 200

    func approvalRequested(tenantID: UUID, run: HermesRunDTO) async {
        let body = Self.bodyText(run.pendingApproval?.command) ?? "A tool call is waiting for your approval"
        var payload = Self.basePayload(run)
        payload["choices"] = (run.pendingApproval?.choices ?? HermesApprovalChoice.allCases).map(\.rawValue).joined(separator: ",")
        await deliver(tenantID: tenantID, title: Self.approvalTitle, body: body, category: .approval, payload: payload)
    }

    func runFinished(tenantID: UUID, run: HermesRunDTO) async {
        let title = switch run.status {
        case .completed: "Hermes finished a run"
        case .failed: "Hermes run failed"
        case .stopped: "Hermes run stopped"
        case .lost: "Hermes run was lost"
        case .queued, .running, .waitingForApproval: "Hermes run update"
        }
        let body = Self.bodyText(run.summary) ?? Self.bodyText(run.error) ?? Self.bodyText(run.prompt) ?? run.status.rawValue
        await deliver(tenantID: tenantID, title: title, body: body, category: .runCompleted, payload: Self.basePayload(run))
    }

    private func deliver(tenantID: UUID, title: String, body: String, category: APNSPushCategory, payload: [String: String]) async {
        do {
            try await push.notify(userID: tenantID, title: title, subtitle: nil, body: body, category: category, payload: payload)
        } catch {
            logger.warning("hermes runs push failed", metadata: [
                "category": .string(category.rawValue),
                "run": .string(payload["runID"] ?? ""),
                "error": .string(Logger.redact(String(describing: error))),
            ])
        }
    }

    private static func basePayload(_ run: HermesRunDTO) -> [String: String] {
        ["runID": run.id.uuidString, "hermesRunID": run.hermesRunID, "status": run.status.rawValue]
    }

    /// Single line, bearer-redacted, capped — a lock-screen body, not a log.
    static func bodyText(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let oneLine = Logger.redact(raw)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !oneLine.isEmpty else { return nil }
        if oneLine.count <= bodyLimit {
            return oneLine
        }
        return String(oneLine.prefix(bodyLimit - 1)) + "…"
    }
}
