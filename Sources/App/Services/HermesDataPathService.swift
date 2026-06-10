import Foundation
import Logging

/// Shared filesystem layout for the bind-mounted Hermes data root.
///
/// Both the `hummingbird` app (uid 999) and the Hermes container write under
/// `<hermesDataRoot>/profiles/<username>/`. Hermes owns the tree; the app
/// mirrors `SOUL.md` there on every `PUT /v1/soul`. Startup and the Hermes
/// entrypoint must keep `profiles/` present and cross-container writable.
struct HermesDataPathService {
    static let profilesDirName = "profiles"

    let hermesDataRoot: String

    func profilesRoot() -> URL {
        URL(fileURLWithPath: hermesDataRoot, isDirectory: true)
            .appendingPathComponent(Self.profilesDirName, isDirectory: true)
    }

    func profileDirectory(for username: String) -> URL {
        profilesRoot().appendingPathComponent(username, isDirectory: true)
    }

    /// Idempotent: creates `profiles/` when missing and verifies the app process
    /// can write there. Call at server boot (filesystem gateway) and before any
    /// Hermes-profile filesystem mutation.
    func ensureProfilesDirectoryWritable(logger: Logger) throws {
        let fm = FileManager.default
        let profiles = profilesRoot()

        do {
            try fm.createDirectory(at: profiles, withIntermediateDirectories: true)
        } catch {
            throw HermesDataError.notWritable(
                path: profiles.path,
                reason: "could not create profiles directory: \(error)",
            )
        }

        let probe = profiles.appendingPathComponent(".write-probe-\(UUID().uuidString)")
        do {
            try Data().write(to: probe)
            try fm.removeItem(at: probe)
        } catch {
            throw HermesDataError.notWritable(
                path: profiles.path,
                reason: "profiles directory is not writable by the app process: \(error)",
            )
        }

        logger.debug("hermes profiles directory writable at \(profiles.path)")
    }
}

enum HermesDataError: Error, CustomStringConvertible {
    case notWritable(path: String, reason: String)

    var description: String {
        switch self {
        case let .notWritable(path, reason):
            """
            Hermes profiles directory not writable at \(path). \(reason) \
            Ensure data/hermes/profiles exists and is writable by the hummingbird \
            user (see docs/startup.md and docker/hermes-entrypoint.sh).
            """
        }
    }
}