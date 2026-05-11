import Foundation
import Logging

enum HermesGatewayError: Error {
    case usernameCollision
    case ioFailure(String)
}

/// Real Hermes profile provisioning via the shared `./data/hermes` Docker volume.
///
/// Both the `hummingbird` and `hermes-agent` containers mount the same host
/// directory (Hummingbird side: `/app/data/hermes`; Hermes side: `/opt/data`).
/// Writing `profiles/<username>/profile.json` here makes the profile visible
/// to the Hermes container without needing `/var/run/docker.sock` or an HTTP
/// profile-management API (which the upstream image does not document).
///
/// Layout assumption — `profiles/<username>/profile.json` — is unverified
/// against the upstream `nousresearch/hermes-agent` image. If the real layout
/// differs (e.g. `agents/`, `tenants/`, `profile.yaml`), only this file
/// needs to change.
struct FilesystemHermesGateway: HermesGateway {
    let rootPath: String
    let logger: Logger

    func provisionProfile(tenantID: UUID, username: String) async throws -> String {
        let fm = FileManager.default
        let profilesRoot = URL(fileURLWithPath: rootPath, isDirectory: true)
            .appendingPathComponent("profiles", isDirectory: true)
        let dir = profilesRoot.appendingPathComponent(username, isDirectory: true)
        let configURL = dir.appendingPathComponent("profile.json")

        if fm.fileExists(atPath: configURL.path) {
            let existing = try Data(contentsOf: configURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let cfg = try decoder.decode(HermesProfileConfig.self, from: existing)
            guard cfg.tenantID == tenantID else {
                throw HermesGatewayError.usernameCollision
            }
            logger.info("hermes profile already provisioned at \(dir.path)")
            return username
        }

        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let cfg = HermesProfileConfig(
                username: username,
                tenantID: tenantID,
                createdAt: Date(),
                schemaVersion: 1,
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let payload = try encoder.encode(cfg)

            let tmp = dir.appendingPathComponent("profile.json.tmp")
            try payload.write(to: tmp, options: .atomic)
            if fm.fileExists(atPath: configURL.path) {
                try fm.removeItem(at: configURL)
            }
            try fm.moveItem(at: tmp, to: configURL)
        } catch let gwErr as HermesGatewayError {
            throw gwErr
        } catch {
            throw HermesGatewayError.ioFailure(String(describing: error))
        }

        logger.info("hermes profile provisioned at \(dir.path)")
        return username
    }

    func deleteProfile(hermesProfileID: String) async throws {
        let fm = FileManager.default
        let profilesRoot = URL(fileURLWithPath: rootPath, isDirectory: true)
            .appendingPathComponent("profiles", isDirectory: true)
        let dir = profilesRoot.appendingPathComponent(hermesProfileID, isDirectory: true)
        guard fm.fileExists(atPath: dir.path) else { return }

        let stamp = Int(Date().timeIntervalSince1970)
        let stamped = profilesRoot.appendingPathComponent("_deleted_\(stamp)_\(hermesProfileID)", isDirectory: true)
        do {
            try fm.moveItem(at: dir, to: stamped)
            logger.info("hermes profile soft-deleted: \(hermesProfileID) -> \(stamped.lastPathComponent)")
        } catch {
            throw HermesGatewayError.ioFailure(String(describing: error))
        }
    }
}

private struct HermesProfileConfig: Codable {
    let username: String
    let tenantID: UUID
    let createdAt: Date
    let schemaVersion: Int
}
