import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import SQLKit

/// A deterministic evidence packet for one document.
///
/// Search answers "where is this mentioned?". Context answers "what else should
/// be understood alongside it?" — the structure of the document, its neighbours
/// in the same Space, and the documents it links to and from.
///
/// No LLM, no scoring, no ranking. Everything here is a direct read of the
/// index, so two calls with the same vault return byte-identical results and an
/// agent can be held to what it was given.
struct VaultContextPacket: Codable, Sendable {
    struct Heading: Codable, Sendable {
        /// Full ancestry, outermost first.
        let path: [String]
        /// First line of the section this heading opens.
        let startLine: Int
    }

    struct Neighbour: Codable, Sendable {
        let vaultFileID: UUID
        let path: String
    }

    let vaultFileID: UUID
    let path: String
    let spaceID: UUID?
    let chunkCount: Int
    /// Section structure, in document order.
    let headings: [Heading]
    /// Other documents in the same Space.
    let siblings: [Neighbour]
    /// Documents this one links to, resolved only.
    let linksTo: [Neighbour]
    /// Documents that link here — backlinks.
    let linkedFrom: [Neighbour]
    /// Links that point nowhere or to more than one document, verbatim as
    /// written. Surfaced rather than hidden: they are the honest edges of the
    /// packet, and an agent should know the trail stops here.
    let danglingLinks: [String]
}

/// Read-only navigation over the chunk and link indexes.
///
/// Mirrors NexusOS's `navigation_service`: never mutates anything, never
/// creates state as a side effect of being read.
struct VaultNavigationService: Sendable {
    let fluent: Fluent
    let links: VaultLinkRepository

    /// How many same-Space neighbours to return. Bounded because a Space can
    /// hold thousands of notes and a context packet is meant to fit in a prompt.
    static let defaultSiblingLimit = 25
    static let maxSiblingLimit = 100

    func context(
        tenantID: UUID,
        vaultFileID: UUID,
        siblingLimit: Int = defaultSiblingLimit
    ) async throws -> VaultContextPacket {
        guard let sql = fluent.db() as? any SQLDatabase else {
            throw HTTPError(.internalServerError, message: "SQL driver required for context")
        }
        let siblingLimit = max(1, min(siblingLimit, Self.maxSiblingLimit))

        guard let file = try await VaultFile.query(on: fluent.db(), tenantID: tenantID)
            .filter(\.$id == vaultFileID).first()
        else {
            throw HTTPError(.notFound, message: "no vault file with that id")
        }

        // Headings come from the chunk index rather than a re-parse: it is the
        // same structure search returns, so context and citations agree.
        let headingRows = try await sql.raw("""
        SELECT heading_path::text AS heading_path_json, MIN(start_line) AS start_line
        FROM memory_chunks
        WHERE tenant_id = \(bind: tenantID) AND vault_file_id = \(bind: vaultFileID)
        GROUP BY heading_path::text
        ORDER BY MIN(start_line)
        """).all(decoding: HeadingRow.self)

        let headings = headingRows.compactMap { row -> VaultContextPacket.Heading? in
            let path = MemoryChunkRepository.decodeHeadingPath(row.heading_path_json)
            guard !path.isEmpty else { return nil }
            return VaultContextPacket.Heading(path: path, startLine: row.start_line)
        }

        let chunkCount = try await sql.raw("""
        SELECT COUNT(*) AS total FROM memory_chunks
        WHERE tenant_id = \(bind: tenantID) AND vault_file_id = \(bind: vaultFileID)
        """).first(decoding: TotalRow.self)?.total ?? 0

        // Siblings: same Space, excluding self. An unfiled document has no
        // Space, and therefore no siblings — not "every unfiled note".
        var siblings: [VaultContextPacket.Neighbour] = []
        if let spaceID = file.spaceID {
            siblings = try await sql.raw("""
            SELECT id, path FROM vault_files
            WHERE tenant_id = \(bind: tenantID)
              AND space_id = \(bind: spaceID)
              AND id <> \(bind: vaultFileID)
            ORDER BY path
            LIMIT \(bind: siblingLimit)
            """).all(decoding: NeighbourRow.self).map {
                VaultContextPacket.Neighbour(vaultFileID: $0.id, path: $0.path)
            }
        }

        let outgoing = try await links.outgoing(tenantID: tenantID, vaultFileID: vaultFileID)
        let incoming = try await links.incoming(tenantID: tenantID, vaultFileID: vaultFileID)

        let linksTo = try await resolveNeighbours(
            sql: sql,
            tenantID: tenantID,
            paths: outgoing.compactMap(\.targetPath)
        )
        let linkedFrom = try await resolveNeighbours(
            sql: sql,
            tenantID: tenantID,
            paths: incoming.compactMap(\.sourcePath)
        )
        let dangling = outgoing
            .filter { $0.resolutionState != WikilinkResolutionState.resolved.rawValue }
            .map(\.rawTarget)

        return VaultContextPacket(
            vaultFileID: vaultFileID,
            path: file.path,
            spaceID: file.spaceID,
            chunkCount: chunkCount,
            headings: headings,
            siblings: siblings,
            linksTo: linksTo,
            linkedFrom: linkedFrom,
            danglingLinks: Array(Set(dangling)).sorted()
        )
    }

    /// Turn a list of paths into deduplicated neighbours, dropping any that no
    /// longer exist.
    private func resolveNeighbours(
        sql: any SQLDatabase,
        tenantID: UUID,
        paths: [String]
    ) async throws -> [VaultContextPacket.Neighbour] {
        let unique = Array(Set(paths)).sorted()
        guard !unique.isEmpty else { return [] }
        return try await sql.raw("""
        SELECT id, path FROM vault_files
        WHERE tenant_id = \(bind: tenantID) AND path = ANY(\(bind: unique))
        ORDER BY path
        """).all(decoding: NeighbourRow.self).map {
            VaultContextPacket.Neighbour(vaultFileID: $0.id, path: $0.path)
        }
    }
}

private struct HeadingRow: Decodable {
    let heading_path_json: String?
    let start_line: Int
}

private struct NeighbourRow: Decodable {
    let id: UUID
    let path: String
}

private struct TotalRow: Decodable {
    let total: Int
}
