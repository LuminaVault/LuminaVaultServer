import Foundation
import HTTPTypes
import Hummingbird
import Logging
import ServiceLifecycle
import Synchronization

/// Free space on the volume that holds the vault.
struct DiskSpace: Sendable, Equatable {
    let freeBytes: Int64
    let totalBytes: Int64
}

/// Refuses user-file writes that would leave the data volume nearly full.
///
/// The vault lives on a `local-path` PVC, which is a directory on the single
/// node's root disk with no enforced size. Plan quotas bound what one tenant
/// may hold (up to 1 TiB) and ingestion bounds one batch (5 GiB), but neither
/// knows how big the disk is. A full root disk takes the whole node down —
/// Postgres, Hermes, every app — not just uploads, so this refuses the write
/// while there is still room to recover.
///
/// A write is rejected when, after it, free space would drop below
/// `minFreeBytes` **or** below `minFreeRatio` of the volume. Either floor at
/// zero switches that floor off.
///
/// Fails **open** when the volume cannot be measured: an unreadable `statvfs`
/// must not block every upload, and the failure is logged.
///
/// The measurement is cached for `cacheTTL` so the check costs one syscall
/// every few seconds at most, not one per chunk.
final class DiskSpaceGuard: Sendable {
    typealias FreeSpaceProvider = @Sendable (String) throws -> DiskSpace

    let path: String
    let minFreeBytes: Int64
    let minFreeRatio: Double
    let cacheTTL: TimeInterval
    /// How often the low-space log line may repeat while the volume stays low.
    let warnInterval: TimeInterval
    private let provider: FreeSpaceProvider
    private let now: @Sendable () -> Date
    private let logger: Logger

    private struct State {
        /// `nil` inside the TTL means the last measurement failed.
        var cached: DiskSpace?
        var cachedAt: Date?
        var lastWarnedAt: Date?
        var lastFailureLoggedAt: Date?
    }

    private let state = Mutex(State())

    static let defaultMinFreeBytes: Int64 = 3 * 1024 * 1024 * 1024
    static let defaultMinFreeRatio = 0.10

    init(
        path: String,
        minFreeBytes: Int64 = DiskSpaceGuard.defaultMinFreeBytes,
        minFreeRatio: Double = DiskSpaceGuard.defaultMinFreeRatio,
        cacheTTL: TimeInterval = 5,
        warnInterval: TimeInterval = 60,
        provider: @escaping FreeSpaceProvider = DiskSpaceGuard.statvfsProvider,
        now: @escaping @Sendable () -> Date = { Date() },
        logger: Logger
    ) {
        self.path = path
        self.minFreeBytes = max(0, minFreeBytes)
        self.minFreeRatio = min(max(0, minFreeRatio), 1)
        self.cacheTTL = cacheTTL
        self.warnInterval = warnInterval
        self.provider = provider
        self.now = now
        self.logger = logger
    }

    /// Throws `InsufficientStorageError` when writing `incomingBytes` would
    /// leave the volume below either floor.
    func check(incomingBytes: Int64) throws {
        guard let space = measure() else { return }
        if Self.isBelowFloor(space: space, incoming: 0, minFreeBytes: minFreeBytes, minFreeRatio: minFreeRatio) {
            warnIfDue(space: space)
        }
        if Self.isBelowFloor(space: space, incoming: max(0, incomingBytes), minFreeBytes: minFreeBytes, minFreeRatio: minFreeRatio) {
            throw InsufficientStorageError()
        }
    }

    /// Re-measures (respecting the cache) and logs if the volume is already
    /// below a floor. `DiskSpaceMonitorService` calls this every minute so the
    /// alert fires on a filling disk even when no one is uploading.
    func sample() {
        guard let space = measure() else { return }
        if Self.isBelowFloor(space: space, incoming: 0, minFreeBytes: minFreeBytes, minFreeRatio: minFreeRatio) {
            warnIfDue(space: space)
        }
    }

    static func isBelowFloor(space: DiskSpace, incoming: Int64, minFreeBytes: Int64, minFreeRatio: Double) -> Bool {
        let after = space.freeBytes - incoming
        if after < minFreeBytes {
            return true
        }
        guard space.totalBytes > 0, minFreeRatio > 0 else { return false }
        return Double(after) / Double(space.totalBytes) < minFreeRatio
    }

    private func measure() -> DiskSpace? {
        let current = now()
        let hit = state.withLock { s -> (fresh: Bool, space: DiskSpace?) in
            guard let at = s.cachedAt, current.timeIntervalSince(at) < cacheTTL else { return (false, nil) }
            return (true, s.cached)
        }
        if hit.fresh {
            return hit.space
        }
        do {
            let space = try provider(path)
            state.withLock {
                $0.cached = space
                $0.cachedAt = current
            }
            return space
        } catch {
            // The failure is cached for the TTL too, so a broken mount does
            // not turn into one failing syscall per upload chunk.
            let shouldLog = state.withLock { s -> Bool in
                s.cached = nil
                s.cachedAt = current
                guard s.lastFailureLoggedAt.map({ current.timeIntervalSince($0) >= warnInterval }) ?? true else { return false }
                s.lastFailureLoggedAt = current
                return true
            }
            if shouldLog {
                logger.warning("storage.disk_check_failed", metadata: [
                    "path": .string(path),
                    "error": .string("\(error)"),
                ])
            }
            return nil
        }
    }

    private func warnIfDue(space: DiskSpace) {
        let current = now()
        let due = state.withLock { s -> Bool in
            guard s.lastWarnedAt.map({ current.timeIntervalSince($0) >= warnInterval }) ?? true else { return false }
            s.lastWarnedAt = current
            return true
        }
        guard due else { return }
        // `.error`, not `.warning`: the platform's Loki rule only counts
        // `level=~"error|critical"`, and a node about to run out of disk is
        // exactly what that alert is for.
        logger.error("storage.disk_low", metadata: [
            "path": .string(path),
            "free_bytes": .stringConvertible(space.freeBytes),
            "total_bytes": .stringConvertible(space.totalBytes),
            "min_free_bytes": .stringConvertible(minFreeBytes),
            "min_free_ratio": .stringConvertible(minFreeRatio),
        ])
    }

    /// `statvfs(3)` on the given path. `f_bavail` (blocks available to an
    /// unprivileged process) rather than `f_bfree`: the server does not run as
    /// root, so the reserved blocks are not space it can use.
    ///
    /// Measures the nearest existing ancestor when the vault root has not been
    /// created yet (first boot), which is the volume it will be created on.
    static let statvfsProvider: FreeSpaceProvider = { path in
        var probe = URL(fileURLWithPath: path).standardizedFileURL
        while !FileManager.default.fileExists(atPath: probe.path), probe.path != "/" {
            probe.deleteLastPathComponent()
        }
        var stats = statvfs()
        guard statvfs(probe.path, &stats) == 0 else {
            throw DiskSpaceGuardError.statvfsFailed(path: probe.path, errno: errno)
        }
        let fragment = UInt64(stats.f_frsize)
        let free = UInt64(stats.f_bavail) &* fragment
        let total = UInt64(stats.f_blocks) &* fragment
        return DiskSpace(
            freeBytes: Int64(clamping: free),
            totalBytes: Int64(clamping: total)
        )
    }
}

enum DiskSpaceGuardError: Error, CustomStringConvertible {
    case statvfsFailed(path: String, errno: Int32)

    var description: String {
        switch self {
        case let .statvfsFailed(path, code):
            "statvfs(\(path)) failed: errno \(code)"
        }
    }
}

/// HTTP 507 for a write refused by `DiskSpaceGuard`.
///
/// Same `{error:{code,message}}` envelope as the other coded errors
/// (`usage_cap_exceeded`, `free_lane_unavailable`) so clients render it the
/// same way. No `cta`: nothing the user can buy or configure fixes a full
/// server disk. No `Retry-After` either, because there is no honest time to
/// promise.
struct InsufficientStorageError: Error, Equatable, HTTPResponseError {
    let reasonCode = "insufficient_storage"
    let userMessage = "LuminaVault is short on storage space right now, so this wasn't saved. Please try again later."

    var status: HTTPResponse.Status {
        HTTPResponse.Status(code: 507, reasonPhrase: "Insufficient Storage")
    }

    var bodyData: Data {
        let envelope: [String: Any] = [
            "error": [
                "code": reasonCode,
                "message": userMessage,
            ],
        ]
        return (try? JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])) ?? Data()
    }

    func response(from _: Request, context _: some RequestContext) throws -> Response {
        var headers = HTTPFields()
        headers[.contentType] = "application/json"
        return Response(
            status: status,
            headers: headers,
            body: .init(byteBuffer: ByteBuffer(data: bodyData))
        )
    }
}

/// Samples the vault volume once a minute so a filling disk is logged (and
/// alerted on) even while nobody is uploading.
struct DiskSpaceMonitorService: Service {
    let guardrail: DiskSpaceGuard
    var interval: Duration = .seconds(60)

    func run() async throws {
        while !Task.isShuttingDownGracefully, !Task.isCancelled {
            guardrail.sample()
            do {
                try await cancelWhenGracefulShutdown {
                    try await Task.sleep(for: interval)
                }
            } catch {
                return
            }
        }
    }
}
