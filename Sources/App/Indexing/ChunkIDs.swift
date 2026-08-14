import Crypto
import Foundation

/// Deterministic, tenant-scoped identifiers for indexed documents and chunks.
///
/// The two IDs have deliberately different stability contracts:
///
/// - `documentID` is derived from tenant + normalized path only, so it survives
///   edits and reindexing. A citation recorded months ago still resolves.
/// - `chunkID` folds in the ordinal and the content hash, so it changes the
///   moment the chunk's text or position changes. That is what lets the indexer
///   detect "this chunk is unchanged, skip the embedding call".
///
/// Neither ID carries absolute paths, machine identity, or raw tenant UUIDs in
/// recoverable form — they are one-way hashes, safe to log and to hand to an agent.
enum ChunkIDs {
    static let documentPrefix = "lv_doc_"
    static let chunkPrefix = "lv_chk_"

    /// Hex characters kept from each SHA-256 digest. 128 bits of a hash the
    /// attacker cannot grind anyway; collision risk is negligible at vault scale.
    private static let digestLength = 32

    /// Stable across reindexing and content changes; distinct across tenants.
    static func documentID(tenantID: UUID, path: String) -> String {
        documentPrefix + digest("\(tenantID.uuidString)\u{0}\(normalize(path))")
    }

    /// Changes whenever the chunk's content or position changes.
    static func chunkID(documentID: String, ordinal: Int, contentSHA256: String) -> String {
        chunkPrefix + digest("\(documentID)\u{0}\(ordinal)\u{0}\(contentSHA256)")
    }

    /// Forward-slash form without a leading `./`, so the same file always hashes
    /// the same way regardless of how the caller spelled its path.
    static func normalize(_ path: String) -> String {
        var normalized = path.replacingOccurrences(of: "\\", with: "/")
        while normalized.hasPrefix("./") {
            normalized = String(normalized.dropFirst(2))
        }
        while normalized.hasPrefix("/") {
            normalized = String(normalized.dropFirst())
        }
        return normalized
    }

    private static func digest(_ value: String) -> String {
        let hex = SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(digestLength))
    }
}
