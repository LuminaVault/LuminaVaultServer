import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import Logging
import ServiceLifecycle

struct LapseArchiverSummary: Codable, ResponseEncodable {
    let lapsed: Int
    let archived: Int
    let hardDeleted: Int
    let failures: [LapseArchiverFailure]
}

struct LapseArchiverFailure: Codable {
    let userID: UUID
    let phase: String
    let error: String
}

struct LapseArchiverJob {
    let fluent: Fluent
    let vaultPaths: VaultPathService
    let coldStorageRoot: URL
    let logger: Logger
    var archiveGraceDays = 90
    var hardDeleteGraceDays = 365

    init(
        fluent: Fluent,
        vaultPaths: VaultPathService,
        coldStoragePath: String,
        logger: Logger,
    ) {
        self.fluent = fluent
        self.vaultPaths = vaultPaths
        coldStorageRoot = URL(fileURLWithPath: coldStoragePath)
        self.logger = logger
    }

    func run(now: Date = Date()) async throws -> LapseArchiverSummary {
        let users = try await User.query(on: fluent.db()).all()
        var lapsed = 0
        var archived = 0
        var hardDeleted = 0
        var failures: [LapseArchiverFailure] = []

        for user in users {
            guard let userID = user.id else { continue }
            do {
                if try await lapseIfExpired(user, now: now) {
                    lapsed += 1
                }
            } catch {
                failures.append(.init(userID: userID, phase: "lapse", error: String(describing: error)))
            }
        }

        for user in users where user.tier == UserTier.lapsed.rawValue {
            guard let userID = user.id else { continue }
            do {
                if try await archiveIfPastGrace(user, now: now) {
                    archived += 1
                }
            } catch {
                failures.append(.init(userID: userID, phase: "archive", error: String(describing: error)))
            }
        }

        for user in users where user.tier == UserTier.archived.rawValue {
            guard let userID = user.id else { continue }
            do {
                if try await hardDeleteIfPastGrace(user, now: now) {
                    hardDeleted += 1
                }
            } catch {
                failures.append(.init(userID: userID, phase: "hard_delete", error: String(describing: error)))
            }
        }

        logger.info("billing.lapse_archiver lapsed=\(lapsed) archived=\(archived) hardDeleted=\(hardDeleted) failures=\(failures.count)")
        return LapseArchiverSummary(lapsed: lapsed, archived: archived, hardDeleted: hardDeleted, failures: failures)
    }

    private func lapseIfExpired(_ user: User, now: Date) async throws -> Bool {
        guard user.tierOverrideEnum == .none,
              [UserTier.trial.rawValue, UserTier.pro.rawValue, UserTier.ultimate.rawValue].contains(user.tier),
              let expiresAt = user.tierExpiresAt,
              expiresAt < now
        else {
            return false
        }
        user.tier = UserTier.lapsed.rawValue
        try await user.save(on: fluent.db())
        let userID = try user.requireID()
        logger.info("billing.user_lapsed", metadata: ["userID": .string(userID.uuidString)])
        return true
    }

    private func archiveIfPastGrace(_ user: User, now: Date) async throws -> Bool {
        guard user.tierOverrideEnum == .none,
              let expiresAt = user.tierExpiresAt,
              expiresAt < now.addingTimeInterval(TimeInterval(-archiveGraceDays * 86400))
        else {
            return false
        }
        let userID = try user.requireID()
        try moveVaultToColdStorage(userID: userID)
        user.tier = UserTier.archived.rawValue
        try await user.save(on: fluent.db())
        logger.warning("billing.user_archived", metadata: ["userID": .string(userID.uuidString)])
        return true
    }

    private func hardDeleteIfPastGrace(_ user: User, now: Date) async throws -> Bool {
        guard user.tierOverrideEnum == .none,
              let expiresAt = user.tierExpiresAt,
              expiresAt < now.addingTimeInterval(TimeInterval(-hardDeleteGraceDays * 86400))
        else {
            return false
        }
        let userID = try user.requireID()
        try deleteColdStorageVault(userID: userID)
        try await user.delete(force: true, on: fluent.db())
        logger.warning("billing.user_hard_deleted", metadata: ["userID": .string(userID.uuidString)])
        return true
    }

    private func moveVaultToColdStorage(userID: UUID) throws {
        let fm = FileManager.default
        let source = vaultPaths.tenantRoot(for: userID)
        let target = coldStorageRoot.appendingPathComponent(userID.uuidString, isDirectory: true)
        guard fm.fileExists(atPath: source.path) else {
            try fm.createDirectory(at: coldStorageRoot, withIntermediateDirectories: true)
            return
        }
        try fm.createDirectory(at: coldStorageRoot, withIntermediateDirectories: true)
        if fm.fileExists(atPath: target.path) {
            throw LapseArchiverStorageError.targetExists(target.path)
        }
        try fm.moveItem(at: source, to: target)
    }

    private func deleteColdStorageVault(userID: UUID) throws {
        let target = coldStorageRoot.appendingPathComponent(userID.uuidString, isDirectory: true)
        guard FileManager.default.fileExists(atPath: target.path) else { return }
        try FileManager.default.removeItem(at: target)
    }
}

enum LapseArchiverStorageError: Error, CustomStringConvertible {
    case targetExists(String)

    var description: String {
        switch self {
        case let .targetExists(path):
            "cold storage target already exists: \(path)"
        }
    }
}

actor LapseArchiverService: Service {
    private let job: LapseArchiverJob
    private let logger: Logger

    init(job: LapseArchiverJob, logger: Logger) {
        self.job = job
        self.logger = logger
    }

    func run() async throws {
        logger.info("billing.lapse_archiver.service started")
        while !Task.isShuttingDownGracefully, !Task.isCancelled {
            do {
                try await cancelWhenGracefulShutdown {
                    try await Task.sleep(for: .seconds(self.secondsUntilNextRun(now: Date())))
                }
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            guard !Task.isShuttingDownGracefully else { return }
            do {
                _ = try await job.run()
            } catch {
                logger.warning("billing.lapse_archiver.service error \(error)")
            }
        }
    }

    private func secondsUntilNextRun(now: Date) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        var next = calendar.dateComponents([.year, .month, .day], from: now)
        next.hour = 3
        next.minute = 0
        next.second = 0
        let today = calendar.date(from: next) ?? now.addingTimeInterval(3600)
        let target = today > now ? today : calendar.date(byAdding: .day, value: 1, to: today) ?? now.addingTimeInterval(86400)
        return max(1, Int(target.timeIntervalSince(now)))
    }
}
