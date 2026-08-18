import Crypto
import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import Logging

/// Issues and authenticates the per-user bearer tokens that let an
/// outside agent (Claude Code, Codex, Hermes, any MCP client) act as
/// one LuminaVault account on `POST /v1/mcp`.
///
/// The plaintext token exists for exactly one moment: the response to
/// the request that created it. The table holds SHA-256 only.
struct AgentConnectionService: Sendable {
    static let tokenPrefix = "lv_"
    static let placeholderToken = "PASTE_YOUR_KEY_HERE__create_one_below"

    private static let tokenBytes = 32
    private static let displayPrefixLen = tokenPrefix.count + 8
    private static let maxNameLen = 60

    let fluent: Fluent
    let logger: Logger

    init(fluent: Fluent, logger: Logger) {
        self.fluent = fluent
        self.logger = logger
    }

    func issue(tenantID: UUID, name: String, kind: AgentClientKind) async throws -> (AgentConnectionDTO, String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw HTTPError(.badRequest, message: "name_required")
        }
        guard trimmed.count <= Self.maxNameLen else {
            throw HTTPError(.badRequest, message: "name_too_long")
        }

        let token = try Self.newToken()
        let row = AgentConnection()
        row.tenantID = tenantID
        row.name = trimmed
        row.clientKind = kind
        row.tokenHash = Self.hash(token)
        row.tokenPrefix = String(token.prefix(Self.displayPrefixLen))
        try await row.save(on: fluent.db())
        return (try row.asDTO(), token)
    }

    func list(tenantID: UUID) async throws -> [AgentConnectionDTO] {
        try await AgentConnection.query(on: fluent.db(), tenantID: tenantID)
            .filter(\.$revokedAt == nil)
            .sort(\.$createdAt, .descending)
            .all()
            .map { try $0.asDTO() }
    }

    func revoke(id: UUID, tenantID: UUID) async throws {
        guard let row = try await AgentConnection.query(on: fluent.db(), tenantID: tenantID)
            .filter(\.$id == id)
            .filter(\.$revokedAt == nil)
            .first()
        else {
            throw HTTPError(.notFound, message: "not_found")
        }
        row.revokedAt = Date()
        try await row.save(on: fluent.db())
    }

    /// Resolves a presented bearer to the user it acts as. Unknown and
    /// revoked tokens are indistinguishable (`nil`) so a guess cannot
    /// confirm that a token once existed.
    func authenticate(token: String) async throws -> User? {
        guard token.hasPrefix(Self.tokenPrefix) else { return nil }
        let hash = Self.hash(token)
        guard let row = try await AgentConnection.query(on: fluent.db())
            .filter(\.$tokenHash == hash)
            .filter(\.$revokedAt == nil)
            .first()
        else {
            return nil
        }
        guard let user = try await User.find(row.tenantID, on: fluent.db()) else {
            return nil
        }
        row.lastUsedAt = Date()
        do {
            try await row.save(on: fluent.db())
        } catch {
            logger.warning(
                "agent connection touch failed",
                metadata: ["id": .string(row.id?.uuidString ?? "")]
            )
        }
        return user
    }

    static func hash(_ token: String) -> Data {
        Data(SHA256.hash(data: Data(token.utf8)))
    }

    static func newToken() throws -> String {
        var raw = [UInt8](repeating: 0, count: tokenBytes)
        var rng = SystemRandomNumberGenerator()
        for i in raw.indices {
            raw[i] = UInt8.random(in: 0 ... 255, using: &rng)
        }
        let encoded = Data(raw).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return tokenPrefix + encoded
    }
}
