import Foundation
import Logging
import ServiceLifecycle

/// Permanently removes the on-disk data of deleted accounts once the recovery
/// window has passed.
///
/// `AccountDeletionService` does not delete files: it renames the tenant's
/// vault and Hermes profile directories to `_deleted_<unix seconds>_<id>`
/// siblings, so a mistaken deletion can be undone by an operator. Nothing
/// removed those directories afterwards — the deletion service's comment
/// promised an operator cron that never existed — so "deleted" accounts kept
/// their files forever. This is that job.
///
/// Deliberately narrow, because it runs `rm -r` on user data unattended:
///
/// - It only looks at the **direct children** of the configured roots. It
///   never descends looking for candidates.
/// - A child must match the exact name the soft-delete produces
///   (`_deleted_<digits>_<UUID>` under the vault's `tenants/`, or
///   `_deleted_<digits>_<profile id>` under Hermes `profiles/`). Anything
///   else — a live tenant, a stray file, a near-miss name — is left alone.
/// - A candidate that is a symlink, or not a directory, is skipped. Removal
///   uses `lstat` at every level and unlinks symlinks rather than following
///   them, so nothing outside the root can be reached through a link.
/// - Age comes from the timestamp in the name (the moment of deletion). The
///   directory's mtime is only a fallback for a timestamp that will not parse,
///   because mtime moves whenever anything inside is touched.
struct DeletedDataPurgeJob: Sendable {
    /// What a root's soft-deleted children are named after.
    enum Identity: Sendable {
        /// `<vaultRoot>/tenants/` — the tenant UUID.
        case tenantUUID
        /// `<hermesDataRoot>/profiles/` — a Hermes profile id. Account
        /// deletion, the gateway's `deleteProfile` and the orphan reaper all
        /// stamp the same way here.
        case profileName
    }

    struct Root: Sendable {
        let url: URL
        let identity: Identity
        /// Short name for logs (`vault`, `hermes`).
        let label: String
    }

    struct Summary: Sendable, Equatable {
        var purged = 0
        var retained = 0
        var skipped = 0
        var failed = 0
    }

    static let prefix = "_deleted_"
    static let defaultRetentionDays = 30

    let roots: [Root]
    let retention: TimeInterval
    let logger: Logger

    init(roots: [Root], retentionDays: Int = Self.defaultRetentionDays, logger: Logger) {
        self.roots = roots
        // A zero or negative setting would purge on the next tick, which
        // removes the recovery window entirely. Clamp to one day.
        retention = TimeInterval(max(1, retentionDays)) * 86400
        self.logger = logger
    }

    /// The roots that `AccountDeletionService` writes soft-deleted directories into.
    ///
    /// The bare Hermes data root is included because deletion used to rename
    /// `<hermesDataRoot>/<profile id>` — a path that does not exist, since
    /// profiles live under `profiles/` — and any sibling it did produce there
    /// carries the tenant UUID.
    static func roots(vaultPaths: VaultPathService, hermesDataRoot: String) -> [Root] {
        [
            Root(
                url: URL(fileURLWithPath: vaultPaths.rootPath).appendingPathComponent("tenants", isDirectory: true),
                identity: .tenantUUID,
                label: "vault"
            ),
            Root(
                url: HermesDataPathService(hermesDataRoot: hermesDataRoot).profilesRoot(),
                identity: .profileName,
                label: "hermes"
            ),
            Root(url: URL(fileURLWithPath: hermesDataRoot, isDirectory: true), identity: .tenantUUID, label: "hermes-legacy"),
        ]
    }

    /// The name a deletion at `deletedAt` renames a directory to.
    static func directoryName(tenantID: UUID, deletedAt: Date) -> String {
        "\(prefix)\(Int(deletedAt.timeIntervalSince1970))_\(tenantID.uuidString)"
    }

    /// Parses a soft-deleted name. Returns nil for anything that is not
    /// exactly `_deleted_<1–12 digits>_<identity>`. `deletedAt` is nil when
    /// the digits do not form a usable time.
    static func parse(_ name: String, identity: Identity) -> (deletedAt: Date?, id: String)? {
        guard name.hasPrefix(prefix) else { return nil }
        let rest = name.dropFirst(prefix.count)
        guard let underscore = rest.firstIndex(of: "_") else { return nil }
        let digits = rest[..<underscore]
        let id = String(rest[rest.index(after: underscore)...])
        guard (1 ... 12).contains(digits.count), digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        switch identity {
        case .tenantUUID:
            guard id.count == 36, UUID(uuidString: id) != nil else { return nil }
        case .profileName:
            guard isSafeProfileName(id) else { return nil }
        }
        let deletedAt = TimeInterval(String(digits)).map { Date(timeIntervalSince1970: $0) }
        return (deletedAt, id)
    }

    /// Profile ids are usernames: letters, digits, `.`, `_`, `-`. Never a path.
    static func isSafeProfileName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 128, name != ".", name != ".." else { return false }
        return name.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "." || scalar == "_" || scalar == "-")
        }
    }

    func run(now: Date = Date()) -> Summary {
        var summary = Summary()
        for root in roots {
            purge(root: root, now: now, summary: &summary)
        }
        logger.info(
            "account.deletion.purge_run",
            metadata: [
                "purged": .stringConvertible(summary.purged),
                "retained": .stringConvertible(summary.retained),
                "skipped": .stringConvertible(summary.skipped),
                "failed": .stringConvertible(summary.failed),
            ]
        )
        return summary
    }

    private func purge(root: Root, now: Date, summary: inout Summary) {
        let rootPath = root.url.standardizedFileURL.path
        guard FilesystemEntry.kind(atPath: rootPath) == .directory else { return }
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: rootPath)
        } catch {
            summary.failed += 1
            logger.error("account.deletion.purge_list_failed", metadata: [
                "root": .string(root.label),
                "error": .string("\(error)"),
            ])
            return
        }
        for name in names {
            guard let parsed = Self.parse(name, identity: root.identity) else { continue }
            let path = rootPath + "/" + name
            guard FilesystemEntry.kind(atPath: path) == .directory else {
                // A symlink or file wearing the soft-delete name was not made
                // by the deletion service. Leave it for a human.
                summary.skipped += 1
                logger.warning("account.deletion.purge_skipped_not_directory", metadata: [
                    "root": .string(root.label),
                    "name": .string(name),
                ])
                continue
            }
            guard let deletedAt = parsed.deletedAt ?? FilesystemEntry.modificationDate(atPath: path) else {
                summary.skipped += 1
                continue
            }
            guard now.timeIntervalSince(deletedAt) >= retention else {
                summary.retained += 1
                continue
            }
            do {
                try FilesystemEntry.removeTree(atPath: path)
                summary.purged += 1
                // Identifier only — never a file name from inside the tree.
                logger.info("account.deletion.purged", metadata: [
                    "root": .string(root.label),
                    "id": .string(parsed.id),
                    "deletedAt": .string(ISO8601DateFormatter().string(from: deletedAt)),
                ])
            } catch {
                summary.failed += 1
                logger.error("account.deletion.purge_failed", metadata: [
                    "root": .string(root.label),
                    "id": .string(parsed.id),
                    "error": .string("\(error)"),
                ])
            }
        }
    }
}

/// `lstat`-based filesystem helpers that never follow a symlink.
enum FilesystemEntry {
    enum Kind: Equatable {
        case directory
        case symlink
        case other
        case missing
    }

    static func kind(atPath path: String) -> Kind {
        var info = stat()
        guard lstat(path, &info) == 0 else { return .missing }
        // `mode_t(...)`: the S_IF* constants import as Int32 on Glibc but as
        // mode_t on Darwin.
        switch info.st_mode & mode_t(S_IFMT) {
        case mode_t(S_IFDIR): return .directory
        case mode_t(S_IFLNK): return .symlink
        default: return .other
        }
    }

    static func modificationDate(atPath path: String) -> Date? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        #if canImport(Darwin)
            return Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
        #else
            return Date(timeIntervalSince1970: TimeInterval(info.st_mtim.tv_sec))
        #endif
    }

    /// Removes `path` and everything under it. A symlink anywhere in the tree
    /// is unlinked itself; its target is never visited.
    static func removeTree(atPath path: String) throws {
        switch kind(atPath: path) {
        case .missing:
            return
        case .directory:
            for name in try FileManager.default.contentsOfDirectory(atPath: path) {
                try removeTree(atPath: path + "/" + name)
            }
            guard rmdir(path) == 0 else { throw RemoveError(path: path, errno: errno) }
        case .symlink, .other:
            guard unlink(path) == 0 else { throw RemoveError(path: path, errno: errno) }
        }
    }

    struct RemoveError: Error, CustomStringConvertible {
        let path: String
        let errno: Int32

        var description: String {
            "could not remove \(path): errno \(errno)"
        }
    }
}

/// Runs `DeletedDataPurgeJob` once a day at 04:00 UTC — an hour after
/// `LapseArchiverService`, so the two never contend for the disk.
actor DeletedDataPurgeService: Service {
    private let job: DeletedDataPurgeJob
    private let logger: Logger

    init(job: DeletedDataPurgeJob, logger: Logger) {
        self.job = job
        self.logger = logger
    }

    func run() async throws {
        logger.info("account.deletion.purge_service started")
        while !Task.isShuttingDownGracefully, !Task.isCancelled {
            do {
                try await cancelWhenGracefulShutdown {
                    try await Task.sleep(for: .seconds(Self.secondsUntilNextRun(now: Date())))
                }
            } catch {
                return
            }
            guard !Task.isCancelled, !Task.isShuttingDownGracefully else { return }
            _ = job.run()
        }
    }

    static func secondsUntilNextRun(now: Date, hour: Int = 4) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        var next = calendar.dateComponents([.year, .month, .day], from: now)
        next.hour = hour
        next.minute = 0
        next.second = 0
        let today = calendar.date(from: next) ?? now.addingTimeInterval(3600)
        let target = today > now ? today : calendar.date(byAdding: .day, value: 1, to: today) ?? now.addingTimeInterval(86400)
        return max(1, Int(target.timeIntervalSince(now)))
    }
}
