import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import Logging

struct HermesProfileReconcileSummary: Codable {
    let usersScanned: Int
    let profilesCreated: Int
    let profilesRecovered: Int // existed in error state, now ready
    let profilesAlreadyOK: Int
    let failures: [String] // human-readable per-user error
}

struct HermesProfileReapSummary: Codable {
    let dirsScanned: Int
    let orphansSoftDeleted: [String] // original names
    let activeKept: Int
}

struct HermesProfileHealth: Codable {
    let totalUsers: Int
    let profilesReady: Int
    let profilesProvisioning: Int
    let profilesError: Int
    let usersWithoutProfile: Int
    let orphanFilesystemDirs: Int
}

/// Admin-side reconciliation. Idempotent and safe to re-run. Built for
/// after-disaster cleanup (filesystem corruption, mid-deploy crash that
/// stranded a `provisioning` row, manual edits to `data/hermes/`).
struct HermesProfileReconciler {
    let fluent: Fluent
    let service: HermesProfileService
    let vaultPaths: VaultPathService
    let hermesDataRoot: String
    let logger: Logger

    func reconcile() async throws -> HermesProfileReconcileSummary {
        var created = 0
        var recovered = 0
        var alreadyOK = 0
        var failures: [String] = []
        let users = try await User.query(on: fluent.db()).all()

        for user in users {
            let userID = try user.requireID()
            let existing = try await HermesProfile
                .query(on: fluent.db(), tenantID: userID)
                .first()

            do {
                let prevStatus = existing?.status
                _ = try await service.ensure(for: user)
                if existing == nil {
                    created += 1
                } else if prevStatus == "error" || prevStatus == "provisioning" {
                    recovered += 1
                } else {
                    alreadyOK += 1
                }
            } catch {
                failures.append("\(user.username): \(error)")
                logger.warning("reconcile failed for \(user.username): \(error)")
            }
        }

        logger.info("reconcile: scanned=\(users.count) created=\(created) recovered=\(recovered) ok=\(alreadyOK) failures=\(failures.count)")
        return HermesProfileReconcileSummary(
            usersScanned: users.count,
            profilesCreated: created,
            profilesRecovered: recovered,
            profilesAlreadyOK: alreadyOK,
            failures: failures,
        )
    }

    func reapOrphans() async throws -> HermesProfileReapSummary {
        let profilesDir = URL(fileURLWithPath: hermesDataRoot)
            .appendingPathComponent("profiles", isDirectory: true)
        let fm = FileManager.default
        guard fm.fileExists(atPath: profilesDir.path) else {
            return HermesProfileReapSummary(dirsScanned: 0, orphansSoftDeleted: [], activeKept: 0)
        }

        let entries = try fm.contentsOfDirectory(atPath: profilesDir.path)
        let activeIDs = try await Set(
            HermesProfile.query(on: fluent.db()).all(\.$hermesProfileID),
        )

        var orphans: [String] = []
        var kept = 0

        for entry in entries {
            // Skip already-soft-deleted dirs.
            if entry.hasPrefix("_deleted_") { continue }
            if activeIDs.contains(entry) {
                kept += 1
                continue
            }
            let from = profilesDir.appendingPathComponent(entry)
            let stamped = profilesDir.appendingPathComponent(
                "_deleted_\(Int(Date().timeIntervalSince1970))_\(entry)",
            )
            do {
                try fm.moveItem(at: from, to: stamped)
                orphans.append(entry)
                logger.info("reaped orphan profile dir: \(entry)")
            } catch {
                logger.warning("reap failed for \(entry): \(error)")
            }
        }

        return HermesProfileReapSummary(
            dirsScanned: entries.count,
            orphansSoftDeleted: orphans,
            activeKept: kept,
        )
    }

    func health() async throws -> HermesProfileHealth {
        let db = fluent.db()
        let totalUsers = try await User.query(on: db).count()

        let allProfiles = try await HermesProfile.query(on: db).all()
        var ready = 0, provisioning = 0, error = 0
        for p in allProfiles {
            switch p.status {
            case "ready": ready += 1
            case "provisioning": provisioning += 1
            case "error": error += 1
            default: break
            }
        }
        let usersWithProfile = Set(allProfiles.map(\.tenantID)).count
        let withoutProfile = max(0, totalUsers - usersWithProfile)

        // Orphan count = on-disk dirs whose name doesn't match any active hermes_profile_id.
        let profilesDir = URL(fileURLWithPath: hermesDataRoot)
            .appendingPathComponent("profiles", isDirectory: true)
        var orphans = 0
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: profilesDir.path) {
            let active = Set(allProfiles.map(\.hermesProfileID))
            orphans = entries.count(where: { !$0.hasPrefix("_deleted_") && !active.contains($0) })
        }

        return HermesProfileHealth(
            totalUsers: totalUsers,
            profilesReady: ready,
            profilesProvisioning: provisioning,
            profilesError: error,
            usersWithoutProfile: withoutProfile,
            orphanFilesystemDirs: orphans,
        )
    }
}
