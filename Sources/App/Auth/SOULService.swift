import Foundation
import Logging

/// HER-85/86: writes the per-user `SOUL.md`.
///
/// SOUL.md is the per-user Hermes personality manifest. Hermes loads it on
/// every chat turn, so writes must end up in two places:
///
///   1. `<vaultRoot>/tenants/<tenantUUID>/raw/SOUL.md` — exposed via the
///      vault read/export surface to the iOS client.
///   2. `<hermesDataRoot>/profiles/<username>/SOUL.md` — bind-mounted into the
///      Hermes container; this is the file Hermes actually opens.
///
/// Writes are atomic (`write-to-tmp + rename`) so Hermes can never observe a
/// half-written file. The 64 KiB size cap matches the ticket acceptance and
/// keeps prompt-injection / cost-blowup attacks bounded.
struct SOULService {
    let vaultPaths: VaultPathService
    /// Host path to the Hermes data root (the same directory mounted into the
    /// Hermes container at `/opt/data`). Profile dirs live at
    /// `<hermesDataRoot>/profiles/<username>`.
    let hermesDataRoot: String
    let logger: Logger

    static let fileName = "SOUL.md"
    static let maxSizeBytes = 64 * 1024

    // MARK: - Paths

    func vaultFilePath(for tenantID: UUID) -> URL {
        vaultPaths.rawDirectory(for: tenantID).appendingPathComponent(Self.fileName)
    }

    private var hermesPaths: HermesDataPathService {
        HermesDataPathService(hermesDataRoot: hermesDataRoot)
    }

    func hermesFilePath(for username: String) -> URL {
        hermesPaths.profileDirectory(for: username).appendingPathComponent(Self.fileName)
    }

    // MARK: - Init at signup

    /// Writes the default template if `SOUL.md` does not already exist for
    /// this user. Returns `true` when a fresh file was written, `false`
    /// when the file was already present.
    @discardableResult
    func initIfMissing(for user: User, now: Date = Date()) throws -> Bool {
        let tenantID = try user.requireID()
        try vaultPaths.ensureTenantDirectories(for: tenantID)
        let target = vaultFilePath(for: tenantID)

        let fm = FileManager.default
        if fm.fileExists(atPath: target.path) {
            // Vault file already there. Best-effort sync to the Hermes profile
            // dir in case it was created after signup (e.g. dev reset).
            try? mirrorFromVaultToHermes(tenantID: tenantID, username: user.username)
            return false
        }
        let body = SOULDefaultTemplate.render(username: user.username, now: now)
        _ = try write(for: user, body: body)
        logger.info("soul.init tenant=\(tenantID.uuidString)")
        return true
    }

    // MARK: - CRUD

    /// Reads the current SOUL.md for the user. Falls back to the default
    /// template if neither the vault nor the hermes mirror exists.
    func read(for user: User, now: Date = Date()) throws -> String {
        let tenantID = try user.requireID()
        let target = vaultFilePath(for: tenantID)
        if let data = try? Data(contentsOf: target), let s = String(data: data, encoding: .utf8) {
            return s
        }
        // Vault file missing — fall back to the default template (don't write).
        return SOULDefaultTemplate.render(username: user.username, now: now)
    }

    /// Writes the given body to BOTH the vault and Hermes profile paths,
    /// after stripping any user-supplied core block and re-injecting the
    /// canonical `SOULCore` covenant — no write path can persist a SOUL.md
    /// without it. Enforces the 64 KiB cap on the ENFORCED document (the
    /// core counts toward the budget). Atomic per file via tmp+rename.
    /// Returns the enforced body so callers echo what was actually persisted.
    @discardableResult
    func write(for user: User, body: String) throws -> String {
        let enforced = SOULCore.inject(into: body)
        let bodyBytes = enforced.lengthOfBytes(using: .utf8)
        guard bodyBytes <= Self.maxSizeBytes else {
            throw SOULServiceError.tooLarge(bytes: bodyBytes, limit: Self.maxSizeBytes)
        }
        let tenantID = try user.requireID()
        try writeBoth(body: enforced, tenantID: tenantID, username: user.username)
        logger.info("soul.write tenant=\(tenantID.uuidString) bytes=\(bodyBytes)")
        return enforced
    }

    /// Resets SOUL.md to the shipped default template. Returns the rendered
    /// body so the controller can echo it back.
    @discardableResult
    func reset(for user: User, now: Date = Date()) throws -> String {
        let body = SOULDefaultTemplate.render(username: user.username, now: now)
        let enforced = try write(for: user, body: body)
        logger.info("soul.reset tenant=\((try? user.requireID())?.uuidString ?? "?")")
        return enforced
    }

    /// True when the persisted vault SOUL.md exists but lacks the canonical
    /// core covenant (pre-v2 file, or tampered before enforcement shipped).
    func needsCoreMigration(for user: User) -> Bool {
        guard let tenantID = try? user.requireID() else { return false }
        let target = vaultFilePath(for: tenantID)
        guard let data = try? Data(contentsOf: target),
              let body = String(data: data, encoding: .utf8) else { return false }
        return !SOULCore.containsCanonicalCore(body)
    }

    /// Best-effort last-modified timestamp of the vault SOUL.md, surfaced via
    /// `SoulResponse.updatedAt`. Returns nil when the file does not exist yet.
    func updatedAt(for user: User) -> Date? {
        guard let tenantID = try? user.requireID() else { return nil }
        let target = vaultFilePath(for: tenantID)
        let attrs = try? FileManager.default.attributesOfItem(atPath: target.path)
        return attrs?[.modificationDate] as? Date
    }

    // MARK: - Internals

    private func writeBoth(body: String, tenantID: UUID, username: String) throws {
        guard let data = body.data(using: .utf8) else {
            throw SOULServiceError.encodingFailed
        }
        try vaultPaths.ensureTenantDirectories(for: tenantID)
        try atomicWrite(data: data, to: vaultFilePath(for: tenantID))

        try hermesPaths.ensureProfilesDirectoryWritable(logger: logger)
        let hermesTarget = hermesFilePath(for: username)
        try FileManager.default.createDirectory(
            at: hermesTarget.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try atomicWrite(data: data, to: hermesTarget)
    }

    private func mirrorFromVaultToHermes(tenantID: UUID, username: String) throws {
        let vault = vaultFilePath(for: tenantID)
        guard let data = try? Data(contentsOf: vault) else { return }
        let hermesTarget = hermesFilePath(for: username)
        try FileManager.default.createDirectory(
            at: hermesTarget.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try atomicWrite(data: data, to: hermesTarget)
    }

    /// `write(...options: .atomic)` already does tmp+rename, but Foundation's
    /// "atomic" semantics are best-effort on cross-volume moves. Force the
    /// tmp file into the same directory so the rename is always same-FS.
    private func atomicWrite(data: Data, to target: URL) throws {
        let fm = FileManager.default
        let tmp = target.appendingPathExtension("tmp-\(UUID().uuidString.prefix(8))")
        try data.write(to: tmp)
        if fm.fileExists(atPath: target.path) {
            try fm.removeItem(at: target)
        }
        try fm.moveItem(at: tmp, to: target)
    }
}

enum SOULServiceError: Error {
    case encodingFailed
    case tooLarge(bytes: Int, limit: Int)
}
