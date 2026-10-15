import FluentKit
import Foundation
import HummingbirdFluent
import Logging

/// Suggests a Space for a capture the user saved without one.
///
/// Captures land in the inbox unless the user picks a Space, and most never
/// do. This asks the model one narrow question — which of the user's existing
/// Spaces fits this note, if any — and stores the answer as
/// `metadata.suggestedSpaceID`. It never moves anything: the user files the
/// note (or ignores the suggestion), so a wrong guess costs nothing. It never
/// invents a Space either; only the slugs the user already has are accepted.
///
/// Same one-shot JSON technique as `ImportCategorizationService`. No
/// temperature is sent: the Haiku 5.5 trial rejects non-default sampling
/// parameters (platform/infra docs/llm-haiku-trial.md).
struct CaptureFilingService: Sendable {
    let fluent: Fluent
    let transport: any HermesChatTransport
    let vaultPaths: VaultPathService
    let defaultModel: String
    let logger: Logger

    static let snippetChars = 1200

    /// Best-effort: every failure is logged and swallowed, because a missing
    /// suggestion is the normal state of a capture.
    func suggestBestEffort(tenantID: UUID, fileID: UUID) async {
        do {
            if let slug = try await suggest(tenantID: tenantID, fileID: fileID) {
                logger.info("capture.autofile.suggested tenant=\(tenantID) file=\(fileID) space=\(slug)")
            }
        } catch {
            logger.warning("capture.autofile.failed tenant=\(tenantID) file=\(fileID): \(error)")
        }
    }

    /// Returns the suggested Space's slug, or nil when nothing fits or the
    /// file is no longer unfiled.
    @discardableResult
    func suggest(tenantID: UUID, fileID: UUID) async throws -> String? {
        let db = fluent.db()
        guard let file = try await VaultFile.query(on: db, tenantID: tenantID).filter(\.$id == fileID).first(),
              file.spaceID == nil
        else { return nil }
        let spaces = try await Space.query(on: db, tenantID: tenantID).all()
            .filter { $0.slug != ImportService.importedSlug }
        guard !spaces.isEmpty else { return nil }

        let url = try VaultController.resolveInside(rawRoot: vaultPaths.rawDirectory(for: tenantID), relative: file.path)
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }

        let catalog = spaces
            .map { "- \($0.slug): \($0.name)\($0.spaceDescription.map { " — \($0)" } ?? "")" }
            .joined(separator: "\n")
        let system = """
        You file one note into the user's existing Spaces (folders).
        Spaces (slug: name — description):
        \(catalog)

        Pick the single Space this note clearly belongs in, or "none" when no
        Space clearly fits. Sharing a word with a Space name is not enough.
        Return ONLY JSON: {"space":"<slug or none>"}.
        """
        let body = Payload(
            model: defaultModel,
            messages: [
                .init(role: "system", content: system),
                .init(role: "user", content: String(text.prefix(Self.snippetChars))),
            ]
        )
        let raw = try await transport.chatCompletions(
            payload: JSONEncoder().encode(body),
            sessionKey: tenantID.uuidString,
            sessionID: nil
        )
        let content = try JSONDecoder().decode(Response.self, from: raw).choices.first?.message.content ?? ""
        guard let slug = Self.parseSuggestion(content),
              let space = spaces.first(where: { $0.slug == slug })
        else { return nil }

        // Re-check: the user may have filed it while the model was thinking.
        guard let fresh = try await VaultFile.query(on: db, tenantID: tenantID).filter(\.$id == fileID).first(),
              fresh.spaceID == nil
        else { return nil }
        var metadata = fresh.metadata ?? VaultFileMetadata()
        metadata.suggestedSpaceID = try space.requireID()
        fresh.metadata = metadata
        try await fresh.save(on: db)
        return slug
    }

    /// `{"space":"work"}` → "work"; "none", empty, or unparseable → nil.
    static func parseSuggestion(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.contains("```") {
            s = s.replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "")
        }
        if let lo = s.firstIndex(of: "{"), let hi = s.lastIndex(of: "}"), lo < hi {
            s = String(s[lo ... hi])
        }
        guard let data = s.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let slug = (object["space"] as? String)?.trimmingCharacters(in: .whitespaces).lowercased(),
              !slug.isEmpty, slug != "none"
        else { return nil }
        return slug
    }

    private struct Payload: Encodable {
        let model: String
        let messages: [Message]
        let stream = false
    }

    private struct Message: Encodable {
        let role: String
        let content: String
    }

    private struct Response: Decodable {
        struct Choice: Decodable { let message: ChoiceMessage }
        struct ChoiceMessage: Decodable { let content: String? }
        let choices: [Choice]
    }
}
