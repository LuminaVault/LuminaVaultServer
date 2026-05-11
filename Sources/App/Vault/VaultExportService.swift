import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import Logging
import NIOCore

/// HER-91: Streaming ZIP export of a tenant's vault.
///
/// Layout produced (zip root):
/// - `SOUL.md`        — synthesized identity manifest for the user
/// - `memories.json`  — snapshot of the `memories` table for this tenant
/// - `raw/<path>`     — every file under `<rawRoot>/tenants/<userID>/raw/`
///
/// Streaming strategy:
/// - ZIP `STORE` method (no compression) so we can stream files without
///   buffering the whole archive in RAM. Vault contents are markdown +
///   images that are already incompressible enough that STORE pays for
///   itself in CPU and time-to-first-byte.
/// - Each on-disk entry uses the "data descriptor" general-purpose flag
///   (bit 3) so the CRC-32 and sizes are written **after** the file body.
///   We only ever hold one chunk in memory while computing CRC.
/// - Central directory records accumulate in memory (one per entry —
///   roughly 50 + path bytes each — negligible vs file payload).
///
/// 32-bit limits: LFH + data-descriptor fields are uint32, so any single
/// file > 4 GiB or total archive > 4 GiB is rejected with `.contentTooLarge`.
/// Real vaults aren't close; zip64 is a follow-up if/when it matters.
struct VaultExportService {
    let vaultPaths: VaultPathService
    let fluent: Fluent
    let logger: Logger

    /// Chunk size used when streaming each on-disk file into the ZIP body.
    private static let chunkSize = 64 * 1024

    /// Hard cap on each entry's size (zip32 limit minus 1 byte).
    private static let maxEntryBytes: Int64 = 4 * 1024 * 1024 * 1024 - 1

    /// Hard cap on total archive size (entry payloads + headers).
    private static let maxTotalBytes: Int64 = 4 * 1024 * 1024 * 1024 - 1

    func streamExport(
        user: User,
        since: Date?,
        writer: inout some ResponseBodyWriter,
    ) async throws {
        let tenantID = try user.requireID()
        let rawRoot = vaultPaths.rawDirectory(for: tenantID)
        let fm = FileManager.default

        var entries: [CentralEntry] = []
        var offset: UInt64 = 0
        let exportedAt = Date()

        // --- SOUL.md at zip root ---
        // Prefer the authoritative on-disk copy (written by SOULService at
        // signup and editable via /v1/soul). Fall back to a synthesized
        // identity manifest if the file is missing — old accounts created
        // before SOULService existed don't have one yet.
        let soulOnDisk = rawRoot.appendingPathComponent("SOUL.md")
        let soulData: [UInt8]
        let soulMtime: Date
        if let raw = try? Data(contentsOf: soulOnDisk) {
            soulData = Array(raw)
            soulMtime = (try? soulOnDisk.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? exportedAt
        } else {
            soulData = Array(Self.buildSoulMarkdown(user: user, exportedAt: exportedAt).utf8)
            soulMtime = user.updatedAt ?? exportedAt
        }
        try await Self.writeStoredEntry(
            name: "SOUL.md",
            data: soulData,
            mtime: soulMtime,
            offset: &offset,
            entries: &entries,
            writer: &writer,
        )

        // --- memories.json (synthesized snapshot) ---
        let memJSON = try await fetchMemoriesJSON(tenantID: tenantID, since: since)
        try await Self.writeStoredEntry(
            name: "memories.json",
            data: Array(memJSON),
            mtime: exportedAt,
            offset: &offset,
            entries: &entries,
            writer: &writer,
        )

        // --- raw/* files from disk ---
        if fm.fileExists(atPath: rawRoot.path) {
            let files = try Self.enumerateRawFiles(rawRoot: rawRoot, since: since)
            for file in files {
                let zipName = "raw/" + file.relativePath
                try await streamFileEntry(
                    name: zipName,
                    fileURL: file.url,
                    mtime: file.mtime,
                    size: file.size,
                    offset: &offset,
                    entries: &entries,
                    writer: &writer,
                )
            }
        }

        // --- central directory ---
        let cdStart = offset
        var cdSize: UInt64 = 0
        for entry in entries {
            let buf = entry.encodeCentralDirectoryHeader()
            offset += UInt64(buf.count)
            cdSize += UInt64(buf.count)
            try await writer.write(ByteBuffer(bytes: buf))
        }

        // --- EOCD ---
        guard offset <= UInt64(Self.maxTotalBytes) else {
            throw HTTPError(.contentTooLarge, message: "vault export exceeds 4 GiB zip32 limit")
        }
        let eocd = Self.encodeEOCD(
            entryCount: UInt16(entries.count),
            cdSize: UInt32(cdSize),
            cdOffset: UInt32(cdStart),
        )
        try await writer.write(ByteBuffer(bytes: eocd))

        logger.info("vault export tenant=\(tenantID) entries=\(entries.count) bytes=\(offset) since=\(since.map(String.init(describing:)) ?? "-")")
    }

    // MARK: - Memories snapshot

    /// Pulls every memory row for the tenant (optionally filtered by
    /// `created_at >= since`) and encodes as a stable JSON array.
    private func fetchMemoriesJSON(tenantID: UUID, since: Date?) async throws -> Data {
        let db = fluent.db()
        let query = Memory.query(on: db, tenantID: tenantID)
            .sort(\.$createdAt, .ascending)
            .sort(\.$id, .ascending)
        if let since {
            _ = query.filter(\.$createdAt >= since)
        }
        let rows = try await query.all()
        let payload = rows.map { row in
            MemoryExportRow(
                id: row.id,
                content: row.content,
                tags: row.tags,
                createdAt: row.createdAt,
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(payload)
    }

    private struct MemoryExportRow: Codable {
        let id: UUID?
        let content: String
        let tags: [String]?
        let createdAt: Date?
    }

    // MARK: - SOUL.md

    private static func buildSoulMarkdown(user: User, exportedAt: Date) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let tenantID = (try? user.requireID().uuidString) ?? "?"
        var lines: [String] = []
        lines.append("# SOUL")
        lines.append("")
        lines.append("Identity manifest exported from LuminaVault on \(iso.string(from: exportedAt)).")
        lines.append("")
        lines.append("- tenant_id: `\(tenantID)`")
        lines.append("- email: `\(user.email)`")
        lines.append("- username: `\(user.username)`")
        lines.append("- tier: `\(user.tier)`")
        if let exp = user.tierExpiresAt {
            lines.append("- tier_expires_at: `\(iso.string(from: exp))`")
        }
        if let created = user.createdAt {
            lines.append("- created_at: `\(iso.string(from: created))`")
        }
        lines.append("- verified: `\(user.isVerified)`")
        lines.append("")
        lines.append("This file is generated at export time. Re-import is not yet supported.")
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - File enumeration

    private struct RawFile {
        let url: URL
        let relativePath: String
        let size: Int64
        let mtime: Date
    }

    private static func enumerateRawFiles(rawRoot: URL, since: Date?) throws -> [RawFile] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = fm.enumerator(
            at: rawRoot,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles],
            errorHandler: nil,
        ) else {
            return []
        }
        let rootPath = rawRoot.standardizedFileURL.path
        var out: [RawFile] = []
        for case let url as URL in enumerator {
            let resolved = url.standardizedFileURL
            let values = try resolved.resourceValues(forKeys: Set(keys))
            guard values.isRegularFile == true else { continue }
            let size = Int64(values.fileSize ?? 0)
            let mtime = values.contentModificationDate ?? Date()
            if let since, mtime < since { continue }

            let path = resolved.path
            guard path.hasPrefix(rootPath + "/") else { continue }
            let rel = String(path.dropFirst(rootPath.count + 1))
            // Soft-deleted files use `_deleted_<ts>_<flattened>` at the root —
            // never include them in exports.
            guard !rel.hasPrefix("_deleted_") else { continue }
            // SOUL.md is emitted at the zip root by the caller; skip the
            // raw/ copy so we don't ship it twice.
            guard rel != "SOUL.md" else { continue }
            out.append(RawFile(url: resolved, relativePath: rel, size: size, mtime: mtime))
        }
        out.sort { $0.relativePath < $1.relativePath }
        return out
    }

    // MARK: - Entry writers

    /// Stream a single on-disk file into the ZIP body.
    private func streamFileEntry(
        name: String,
        fileURL: URL,
        mtime: Date,
        size: Int64,
        offset: inout UInt64,
        entries: inout [CentralEntry],
        writer: inout some ResponseBodyWriter,
    ) async throws {
        guard size <= Self.maxEntryBytes else {
            throw HTTPError(.contentTooLarge, message: "vault entry exceeds 4 GiB zip32 limit: \(name)")
        }
        let nameBytes = Array(name.utf8)
        let (dosTime, dosDate) = Self.dosDateTime(mtime)
        let entryOffset = offset

        // LFH with zeroed CRC + sizes (data descriptor follows the data).
        let lfh = Self.encodeLocalFileHeader(
            nameBytes: nameBytes,
            dosTime: dosTime,
            dosDate: dosDate,
        )
        offset += UInt64(lfh.count)
        try await writer.write(ByteBuffer(bytes: lfh))

        var crc: UInt32 = 0xFFFF_FFFF
        var written: Int64 = 0
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        while true {
            let data = try handle.read(upToCount: Self.chunkSize) ?? Data()
            if data.isEmpty { break }
            written += Int64(data.count)
            guard written <= size + Int64(Self.chunkSize) else {
                // Defensive: file grew while we were streaming. Bail rather
                // than emit a corrupt archive.
                throw HTTPError(.internalServerError, message: "file size changed during export: \(name)")
            }
            crc = CRC32.update(crc: crc, bytes: data)
            offset += UInt64(data.count)
            try await writer.write(ByteBuffer(bytes: Array(data)))
        }
        let finalCRC = crc ^ 0xFFFF_FFFF
        let entrySize = UInt32(clamping: written)

        // Data descriptor.
        let dd = Self.encodeDataDescriptor(crc: finalCRC, size: entrySize)
        offset += UInt64(dd.count)
        try await writer.write(ByteBuffer(bytes: dd))

        entries.append(CentralEntry(
            name: nameBytes,
            crc: finalCRC,
            size: entrySize,
            offset: UInt32(clamping: entryOffset),
            dosTime: dosTime,
            dosDate: dosDate,
            useDataDescriptor: true,
        ))
    }

    /// In-memory variant for synthesized `SOUL.md` and `memories.json`.
    private static func writeStoredEntry(
        name: String,
        data: [UInt8],
        mtime: Date,
        offset: inout UInt64,
        entries: inout [CentralEntry],
        writer: inout some ResponseBodyWriter,
    ) async throws {
        guard Int64(data.count) <= maxEntryBytes else {
            throw HTTPError(.contentTooLarge, message: "synthesized entry exceeds zip32 limit: \(name)")
        }
        let nameBytes = Array(name.utf8)
        let (dosTime, dosDate) = dosDateTime(mtime)
        let crc = CRC32.checksum(bytes: data)
        let entryOffset = offset

        // Size is known up front; skip data descriptor and inline CRC + sizes.
        let lfh = encodeLocalFileHeader(
            nameBytes: nameBytes,
            dosTime: dosTime,
            dosDate: dosDate,
            crc: crc,
            size: UInt32(data.count),
        )
        offset += UInt64(lfh.count)
        try await writer.write(ByteBuffer(bytes: lfh))

        offset += UInt64(data.count)
        try await writer.write(ByteBuffer(bytes: data))

        entries.append(CentralEntry(
            name: nameBytes,
            crc: crc,
            size: UInt32(data.count),
            offset: UInt32(clamping: entryOffset),
            dosTime: dosTime,
            dosDate: dosDate,
            useDataDescriptor: false,
        ))
    }

    // MARK: - ZIP header encoders

    private struct CentralEntry {
        let name: [UInt8]
        let crc: UInt32
        let size: UInt32
        let offset: UInt32
        let dosTime: UInt16
        let dosDate: UInt16
        let useDataDescriptor: Bool

        /// 46 bytes + name. version-made-by 20, version-needed 20.
        func encodeCentralDirectoryHeader() -> [UInt8] {
            var out: [UInt8] = []
            out.reserveCapacity(46 + name.count)
            appendUInt32(0x0214_4B50, into: &out)
            appendUInt16(20, into: &out) // version made by
            appendUInt16(20, into: &out) // version needed
            appendUInt16(useDataDescriptor ? 0x0008 : 0, into: &out) // general purpose
            appendUInt16(0, into: &out) // method = store
            appendUInt16(dosTime, into: &out)
            appendUInt16(dosDate, into: &out)
            appendUInt32(crc, into: &out)
            appendUInt32(size, into: &out) // compressed
            appendUInt32(size, into: &out) // uncompressed
            appendUInt16(UInt16(name.count), into: &out)
            appendUInt16(0, into: &out) // extra len
            appendUInt16(0, into: &out) // comment len
            appendUInt16(0, into: &out) // disk start
            appendUInt16(0, into: &out) // internal attrs
            appendUInt32(0, into: &out) // external attrs
            appendUInt32(offset, into: &out)
            out.append(contentsOf: name)
            return out
        }
    }

    private static func encodeLocalFileHeader(
        nameBytes: [UInt8],
        dosTime: UInt16,
        dosDate: UInt16,
        crc: UInt32 = 0,
        size: UInt32 = 0,
    ) -> [UInt8] {
        // When crc/size are zero we set the data-descriptor flag so consumers
        // know to look past the body for them.
        let usingDataDescriptor = (crc == 0 && size == 0)
        var out: [UInt8] = []
        out.reserveCapacity(30 + nameBytes.count)
        appendUInt32(0x0403_4B50, into: &out)
        appendUInt16(20, into: &out)
        appendUInt16(usingDataDescriptor ? 0x0008 : 0, into: &out)
        appendUInt16(0, into: &out) // method
        appendUInt16(dosTime, into: &out)
        appendUInt16(dosDate, into: &out)
        appendUInt32(crc, into: &out)
        appendUInt32(size, into: &out)
        appendUInt32(size, into: &out)
        appendUInt16(UInt16(nameBytes.count), into: &out)
        appendUInt16(0, into: &out)
        out.append(contentsOf: nameBytes)
        return out
    }

    private static func encodeDataDescriptor(crc: UInt32, size: UInt32) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(16)
        appendUInt32(0x0807_4B50, into: &out)
        appendUInt32(crc, into: &out)
        appendUInt32(size, into: &out)
        appendUInt32(size, into: &out)
        return out
    }

    private static func encodeEOCD(
        entryCount: UInt16,
        cdSize: UInt32,
        cdOffset: UInt32,
    ) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(22)
        appendUInt32(0x0605_4B50, into: &out)
        appendUInt16(0, into: &out) // disk
        appendUInt16(0, into: &out) // disk where CD starts
        appendUInt16(entryCount, into: &out)
        appendUInt16(entryCount, into: &out)
        appendUInt32(cdSize, into: &out)
        appendUInt32(cdOffset, into: &out)
        appendUInt16(0, into: &out) // comment len
        return out
    }

    private static func dosDateTime(_ date: Date) -> (time: UInt16, date: UInt16) {
        let cal = Calendar(identifier: .gregorian)
        let comps = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        // Clamp year into the 1980..2107 DOS-time range.
        let year = max(1980, min(2107, comps.year ?? 1980))
        let month = comps.month ?? 1
        let day = comps.day ?? 1
        let hour = comps.hour ?? 0
        let minute = comps.minute ?? 0
        let second = (comps.second ?? 0) / 2
        let dosTime = UInt16((hour & 0x1F) << 11 | (minute & 0x3F) << 5 | (second & 0x1F))
        let dosDate = UInt16(((year - 1980) & 0x7F) << 9 | (month & 0x0F) << 5 | (day & 0x1F))
        return (dosTime, dosDate)
    }
}

// MARK: - Little-endian helpers

private func appendUInt16(_ value: UInt16, into buf: inout [UInt8]) {
    buf.append(UInt8(value & 0xFF))
    buf.append(UInt8((value >> 8) & 0xFF))
}

private func appendUInt32(_ value: UInt32, into buf: inout [UInt8]) {
    buf.append(UInt8(value & 0xFF))
    buf.append(UInt8((value >> 8) & 0xFF))
    buf.append(UInt8((value >> 16) & 0xFF))
    buf.append(UInt8((value >> 24) & 0xFF))
}

// MARK: - CRC32 (IEEE polynomial 0xedb88320)

enum CRC32 {
    private static let table: [UInt32] = (0 ..< 256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0 ..< 8 {
            c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1)
        }
        return c
    }

    /// One-shot helper for small in-memory blobs.
    static func checksum(bytes: some Sequence<UInt8>) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for b in bytes {
            crc = table[Int((crc ^ UInt32(b)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }

    /// Streaming update — caller seeds `crc = 0xFFFFFFFF`, feeds chunks,
    /// finalises with `crc ^ 0xFFFFFFFF`.
    static func update(crc: UInt32, bytes: some Sequence<UInt8>) -> UInt32 {
        var c = crc
        for b in bytes {
            c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8)
        }
        return c
    }
}
