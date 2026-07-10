import Foundation
import Hummingbird
import Logging

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

protocol TeamInvitationSending: Sendable {
    func send(to email: String, teamName: String, inviterName: String,
              token: String, expiresAt: Date) async throws
}

struct LoggingTeamInvitationSender: TeamInvitationSending {
    let baseURL: URL
    let logger: Logger

    func send(to email: String, teamName: String, inviterName: String,
              token: String, expiresAt: Date) async throws
    {
        logger.warning("team invitation (dev only): to=\(email) team=\(teamName) inviter=\(inviterName) url=\(inviteURL(token)) expires=\(expiresAt)")
    }

    private func inviteURL(_ token: String) -> URL {
        baseURL.appendingPathComponent("invitations").appendingPathComponent(token)
    }
}

struct ResendTeamInvitationSender: TeamInvitationSending {
    let apiKey: String
    let fromAddress: String
    let replyTo: String
    let baseURL: URL
    let session: URLSession
    let logger: Logger

    func send(to email: String, teamName: String, inviterName: String,
              token: String, expiresAt: Date) async throws
    {
        guard !apiKey.isEmpty, !fromAddress.isEmpty else {
            throw HTTPError(.internalServerError, message: "team invitation email is not configured")
        }
        let url = baseURL.appendingPathComponent("invitations").appendingPathComponent(token)
        let safeTeam = escape(teamName)
        let safeInviter = escape(inviterName)
        var payload: [String: Any] = [
            "from": fromAddress,
            "to": [email],
            "subject": "\(inviterName) invited you to \(teamName) on LuminaVault",
            "text": "\(inviterName) invited you to collaborate in \(teamName). Accept before \(expiresAt): \(url.absoluteString)",
            "html": "<p><strong>\(safeInviter)</strong> invited you to collaborate in <strong>\(safeTeam)</strong>.</p><p><a href=\"\(url.absoluteString)\">Accept invitation</a></p><p>This invitation expires in 7 days.</p>",
        ]
        if !replyTo.isEmpty {
            payload["reply_to"] = replyTo
        }
        var request = URLRequest(url: URL(string: "https://api.resend.com/emails")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            let preview = String(data: data.prefix(512), encoding: .utf8) ?? "<binary>"
            logger.error("team invitation email failed: \(preview)")
            throw HTTPError(.badGateway, message: "team invitation email failed")
        }
    }

    private func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

func makeTeamInvitationSender(kind: String, apiKey: String, fromAddress: String,
                              replyTo: String, baseURL: URL, logger: Logger) -> any TeamInvitationSending
{
    if kind.lowercased() == "resend" {
        return ResendTeamInvitationSender(apiKey: apiKey, fromAddress: fromAddress,
                                          replyTo: replyTo, baseURL: baseURL,
                                          session: .shared, logger: logger)
    }
    return LoggingTeamInvitationSender(baseURL: baseURL, logger: logger)
}
