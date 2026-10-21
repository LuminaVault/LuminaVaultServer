@testable import App
import Foundation
import Logging
import Testing

/// `DeletedDataPurgeJob` runs `rm -r` on user data unattended, so these pin
/// what it must *not* touch as much as what it removes.
struct DeletedDataPurgeJobTests {
    private static let day: TimeInterval = 86400
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// A scratch tree: `<base>/vault/tenants`, `<base>/hermes/profiles`, and
    /// `<base>/outside` (which nothing may ever delete from).
    private struct Sandbox {
        let base: URL
        var tenants: URL {
            base.appendingPathComponent("vault/tenants")
        }

        var hermes: URL {
            base.appendingPathComponent("hermes")
        }

        var profiles: URL {
            base.appendingPathComponent("hermes/profiles")
        }

        var outside: URL {
            base.appendingPathComponent("outside")
        }

        init() throws {
            base = FileManager.default.temporaryDirectory
                .appendingPathComponent("purge-\(UUID().uuidString)", isDirectory: true)
            for dir in [tenants, profiles, outside] {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            try Data("keep me".utf8).write(to: outside.appendingPathComponent("precious.txt"))
        }

        func job(retentionDays: Int = 30) -> DeletedDataPurgeJob {
            DeletedDataPurgeJob(
                roots: DeletedDataPurgeJob.roots(
                    vaultPaths: VaultPathService(rootPath: base.appendingPathComponent("vault").path),
                    hermesDataRoot: hermes.path
                ),
                retentionDays: retentionDays,
                logger: Logger(label: "test.purge")
            )
        }

        @discardableResult
        func makeDir(_ parent: URL, _ name: String) throws -> URL {
            let dir = parent.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: dir.appendingPathComponent("raw"), withIntermediateDirectories: true)
            try Data("note".utf8).write(to: dir.appendingPathComponent("raw/note.md"))
            return dir
        }

        func exists(_ url: URL) -> Bool {
            FilesystemEntry.kind(atPath: url.path) != .missing
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: base)
        }
    }

    private func stamp(daysAgo: Double) -> Int {
        Int(now.timeIntervalSince1970 - daysAgo * Self.day)
    }

    @Test
    func `purges only correctly named directories past retention`() throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let tenant = UUID()

        let old = try box.makeDir(box.tenants, DeletedDataPurgeJob.directoryName(tenantID: tenant, deletedAt: now.addingTimeInterval(-31 * Self.day)))
        let recent = try box.makeDir(box.tenants, DeletedDataPurgeJob.directoryName(tenantID: UUID(), deletedAt: now.addingTimeInterval(-29 * Self.day)))
        let live = try box.makeDir(box.tenants, UUID().uuidString)
        let notUUID = try box.makeDir(box.tenants, "_deleted_\(stamp(daysAgo: 400))_not-a-uuid")
        let noDigits = try box.makeDir(box.tenants, "_deleted_abc_\(UUID().uuidString)")
        let extraSuffix = try box.makeDir(box.tenants, "_deleted_\(stamp(daysAgo: 400))_\(UUID().uuidString)_x")
        let prefixed = try box.makeDir(box.tenants, "x_deleted_\(stamp(daysAgo: 400))_\(UUID().uuidString)")

        let summary = box.job().run(now: now)

        #expect(!box.exists(old))
        for kept in [recent, live, notUUID, noDigits, extraSuffix, prefixed] {
            #expect(box.exists(kept), "\(kept.lastPathComponent) must survive")
        }
        #expect(summary.purged == 1)
        #expect(summary.retained == 1)
    }

    @Test
    func `purges old Hermes profile soft-deletes and leaves live profiles`() throws {
        let box = try Sandbox()
        defer { box.cleanup() }

        let deletedAccount = try box.makeDir(box.profiles, DeletedDataPurgeJob.directoryName(tenantID: UUID(), deletedAt: now.addingTimeInterval(-60 * Self.day)))
        let reaped = try box.makeDir(box.profiles, "_deleted_\(stamp(daysAgo: 45))_hermes-alice")
        let live = try box.makeDir(box.profiles, "hermes-bob")
        let traversal = try box.makeDir(box.profiles, "_deleted_\(stamp(daysAgo: 45))_..")

        let summary = box.job().run(now: now)

        #expect(!box.exists(deletedAccount))
        #expect(!box.exists(reaped))
        #expect(box.exists(live))
        #expect(box.exists(traversal))
        #expect(summary.purged == 2)
    }

    @Test
    func `never follows a symlink out of the root`() throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let fm = FileManager.default

        // 1. A symlink wearing a valid soft-delete name, pointing outside.
        let trap = box.tenants.appendingPathComponent(
            DeletedDataPurgeJob.directoryName(tenantID: UUID(), deletedAt: now.addingTimeInterval(-90 * Self.day))
        )
        try fm.createSymbolicLink(at: trap, withDestinationURL: box.outside)

        // 2. A real, purgeable directory that contains a symlink to outside.
        let purgeable = try box.makeDir(
            box.tenants,
            DeletedDataPurgeJob.directoryName(tenantID: UUID(), deletedAt: now.addingTimeInterval(-90 * Self.day))
        )
        try fm.createSymbolicLink(at: purgeable.appendingPathComponent("raw/escape"), withDestinationURL: box.outside)

        // 3. A plain file wearing a valid name.
        let file = box.tenants.appendingPathComponent(
            DeletedDataPurgeJob.directoryName(tenantID: UUID(), deletedAt: now.addingTimeInterval(-90 * Self.day))
        )
        try Data("x".utf8).write(to: file)

        let summary = box.job().run(now: now)

        #expect(FilesystemEntry.kind(atPath: trap.path) == .symlink, "a symlinked candidate is skipped, not removed")
        #expect(box.exists(file), "a non-directory candidate is skipped")
        #expect(!box.exists(purgeable))
        #expect(fm.fileExists(atPath: box.outside.appendingPathComponent("precious.txt").path), "nothing outside the root may be deleted")
        #expect(summary.purged == 1)
        #expect(summary.skipped == 2)
    }

    @Test
    func `retention is configurable and never below one day`() throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let tenDays = try box.makeDir(box.tenants, DeletedDataPurgeJob.directoryName(tenantID: UUID(), deletedAt: now.addingTimeInterval(-10 * Self.day)))
        let hourOld = try box.makeDir(box.tenants, DeletedDataPurgeJob.directoryName(tenantID: UUID(), deletedAt: now.addingTimeInterval(-3600)))

        _ = box.job(retentionDays: 0).run(now: now)

        #expect(!box.exists(tenDays))
        #expect(box.exists(hourOld), "a zero setting must not remove the recovery window")
    }

    @Test
    func `missing roots are a no-op`() {
        let job = DeletedDataPurgeJob(
            roots: DeletedDataPurgeJob.roots(
                vaultPaths: VaultPathService(rootPath: "/nonexistent-\(UUID().uuidString)"),
                hermesDataRoot: "/nonexistent-\(UUID().uuidString)"
            ),
            logger: Logger(label: "test.purge")
        )
        #expect(job.run(now: now) == DeletedDataPurgeJob.Summary())
    }

    @Test
    func `parses exactly the deletion service's name`() {
        let tenant = UUID()
        let at = Date(timeIntervalSince1970: 1_700_000_000)
        let name = DeletedDataPurgeJob.directoryName(tenantID: tenant, deletedAt: at)
        let parsed = DeletedDataPurgeJob.parse(name, identity: .tenantUUID)
        #expect(parsed?.id == tenant.uuidString)
        #expect(parsed?.deletedAt == at)
        #expect(DeletedDataPurgeJob.parse("_deleted__\(tenant.uuidString)", identity: .tenantUUID) == nil)
        #expect(DeletedDataPurgeJob.parse("_deleted_1234567890123_\(tenant.uuidString)", identity: .tenantUUID) == nil)
        #expect(DeletedDataPurgeJob.parse("_deleted_1_a/b", identity: .profileName) == nil)
        #expect(DeletedDataPurgeJob.parse("_deleted_1_.", identity: .profileName) == nil)
    }
}
