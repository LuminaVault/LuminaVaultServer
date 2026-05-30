import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import Logging

/// Smart Import — one-shot LLM pass that proposes a Space for each staged import
/// item: an EXISTING Space slug where it fits, or `new:<Name>` for a small
/// capped set of new Spaces, or `imported` (stay in inbox). Writes
/// `import_items.proposed_space` and flips the session to `review`.
///
/// Uses the same one-shot JSON technique as `MemoryCompileService` (no
/// multi-turn tools; NO Gemini `responseMimeType` — it hangs gemini-flash; we
/// ask for JSON in the prompt and parse leniently).
actor ImportCategorizationService {
    let fluent: Fluent
    let transport: any HermesChatTransport
    let vaultPaths: VaultPathService
    let defaultModel: String
    let logger: Logger

    static let maxNewSpaces = 6
    static let snippetChars = 400

    init(
        fluent: Fluent,
        transport: any HermesChatTransport,
        vaultPaths: VaultPathService,
        defaultModel: String,
        logger: Logger,
    ) {
        self.fluent = fluent
        self.transport = transport
        self.vaultPaths = vaultPaths
        self.defaultModel = defaultModel
        self.logger = logger
    }

    func categorize(tenantID: UUID, sessionID: UUID) async throws {
        let db = fluent.db()
        guard let session = try await ImportSession.query(on: db, tenantID: tenantID)
            .filter(\.$id == sessionID).first()
        else { throw HTTPError(.notFound, message: "import session not found") }

        let items = try await ImportItem.query(on: db, tenantID: tenantID)
            .filter(\.$sessionID == sessionID)
            .filter(\.$status != ImportItemStatus.skipped)
            .all()
        guard !items.isEmpty else {
            session.status = ImportStatus.review
            try await session.save(on: db)
            return
        }

        let spaces = try await Space.query(on: db, tenantID: tenantID).all()
        let existingList = spaces
            .filter { $0.slug != ImportService.importedSlug }
            .map { "- \($0.slug): \($0.name)\($0.spaceDescription.map { " — \($0)" } ?? "")" }
            .joined(separator: "\n")

        // Per-item snippet (url + first chars of the staged/enriched file).
        let rawRoot = vaultPaths.rawDirectory(for: tenantID)
        var itemBlocks: [String] = []
        for item in items {
            let id = try item.requireID()
            var snippet = ""
            if let vfID = item.vaultFileID,
               let vf = try await VaultFile.query(on: db, tenantID: tenantID).filter(\.$id == vfID).first(),
               let text = try? String(contentsOf: rawRoot.appendingPathComponent(vf.path), encoding: .utf8)
            {
                snippet = String(text.prefix(Self.snippetChars))
            }
            itemBlocks.append("[id=\(id.uuidString)] url=\(item.url ?? "")\n\(snippet)")
        }

        let system = """
        You are organizing a user's freshly imported items into Spaces (folders).
        Existing Spaces (slug: name):
        \(existingList.isEmpty ? "(none yet)" : existingList)

        For EACH item, choose the single best target:
        - an existing Space slug above, when it clearly fits;
        - "new:<Short Title>" only when several items share a clear theme not
          covered by an existing Space (at most \(Self.maxNewSpaces) distinct new
          Spaces total across all items);
        - "imported" when nothing fits.
        Prefer reusing existing Spaces. Return ONLY JSON of the form
        {"mappings":[{"id":"<item id>","space":"<slug | new:Name | imported>"}]}.
        """

        let body = CategorizePayload(
            model: defaultModel,
            messages: [
                .init(role: "system", content: system),
                .init(role: "user", content: "Items:\n\n" + itemBlocks.joined(separator: "\n\n")),
            ],
            responseFormat: ["type": "json_object"],
            temperature: 0.1,
            stream: false,
        )
        let payload = try JSONEncoder().encode(body)
        let raw = try await transport.chatCompletions(payload: payload, sessionKey: tenantID.uuidString, sessionID: nil)
        let response = try JSONDecoder().decode(CategorizeResponse.self, from: raw)
        let content = response.choices.first?.message.content ?? ""
        let mapping = Self.parseMappings(content)
        logger.info("import categorize tenant=\(tenantID) session=\(sessionID) items=\(items.count) mapped=\(mapping.count)")

        // Enforce the new-Space cap; everything beyond it falls back to inbox.
        var newSpaceOrder: [String] = []
        for item in items {
            let id = try item.requireID().uuidString
            var target = mapping[id] ?? ImportService.importedSlug
            if target.hasPrefix("new:") {
                let name = String(target.dropFirst(4)).trimmingCharacters(in: .whitespaces)
                if !newSpaceOrder.contains(name.lowercased()) {
                    if newSpaceOrder.count >= Self.maxNewSpaces {
                        target = ImportService.importedSlug
                    } else {
                        newSpaceOrder.append(name.lowercased())
                    }
                }
            }
            item.proposedSpace = target
            item.status = ImportItemStatus.categorized
            try await item.save(on: db)
        }

        session.status = ImportStatus.review
        try await session.save(on: db)
    }

    /// Lenient parse of `{"mappings":[{"id","space"}]}` (tolerates code fences /
    /// prose, mirrors MemoryCompileService.parseExtractedMemories).
    static func parseMappings(_ raw: String) -> [String: String] {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.contains("```") {
            s = s.replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func obj(from str: String) -> [String: Any]? {
            if let d = str.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { return o }
            if let lo = str.firstIndex(of: "{"), let hi = str.lastIndex(of: "}"), lo < hi,
               let d = String(str[lo ... hi]).data(using: .utf8),
               let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { return o }
            return nil
        }
        guard let root = obj(from: s), let arr = root["mappings"] as? [[String: Any]] else { return [:] }
        var out: [String: String] = [:]
        for m in arr {
            if let id = m["id"] as? String, let space = m["space"] as? String { out[id] = space }
        }
        return out
    }

    private struct CategorizePayload: Encodable {
        let model: String
        let messages: [Msg]
        let responseFormat: [String: String]
        let temperature: Double?
        let stream: Bool
        enum CodingKeys: String, CodingKey {
            case model, messages, temperature, stream
            case responseFormat = "response_format"
        }
    }

    private struct Msg: Encodable {
        let role: String
        let content: String?
    }

    private struct CategorizeResponse: Decodable {
        struct Choice: Decodable { let message: ChoiceMessage }
        struct ChoiceMessage: Decodable { let content: String? }
        let choices: [Choice]
    }
}
