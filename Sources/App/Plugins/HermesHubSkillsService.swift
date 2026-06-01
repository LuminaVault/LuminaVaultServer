import Foundation
import Hummingbird
import Logging
import LuminaVaultShared

/// HER-43 (Slice 3b) — install/uninstall Hermes Hub skills into the caller's
/// own per-tenant Hermes container.
///
/// Hermes skill management is CLI-only upstream (`hermes skills install <id>`,
/// `hermes skills uninstall <name>`; no HTTP API), so we run it via
/// `docker exec` inside the tenant's container — the same seam XaiOAuth uses
/// for `hermes auth add`. Install is seconds-long (fetch SKILL.md + scan +
/// copy), so it runs synchronously within the request rather than as a
/// HER-330-style async job.
///
/// This is a per-tenant op (your own container), so it is JWT-gated under
/// `/v1/plugins`, not admin-gated like the all-tenant Hermes update.
struct HermesHubSkillsService {
    let docker: any DockerExec
    let containerManager: HermesContainerManager
    let installedSkillsClient: any HermesSkillsClienting
    let logger: Logger

    enum ErrorCode: String {
        case containerNotFound = "hermes_container_not_found"
        case invalidSkillRef = "invalid_skill_ref"
        case installFailed = "hermes_install_failed"
        case uninstallFailed = "hermes_uninstall_failed"
    }

    /// Install a hub skill by id/URL, then return the refreshed read-only list
    /// of the tenant's Hermes-installed skills.
    func install(tenantID: UUID, skillRef: String) async throws -> [PluginCatalogEntryDTO] {
        let ref = try Self.validatedRef(skillRef)
        let handle = try await requireHandle(tenantID: tenantID)
        let result = try await docker.exec(
            container: handle.containerName,
            command: ["hermes", "skills", "install", ref],
            stdin: nil,
        )
        guard result.ok else {
            logger.error("hermes skills install failed tenant=\(tenantID) exit=\(result.exitCode)")
            throw HTTPError(.badGateway, message: ErrorCode.installFailed.rawValue)
        }
        logger.info("hermes skill installed tenant=\(tenantID)")
        return await refreshedInstalled(handle: handle)
    }

    /// Uninstall a skill by name from the tenant's Hermes, then return the
    /// refreshed installed list.
    func uninstall(tenantID: UUID, skillRef: String) async throws -> [PluginCatalogEntryDTO] {
        let ref = try Self.validatedRef(skillRef)
        let handle = try await requireHandle(tenantID: tenantID)
        let result = try await docker.exec(
            container: handle.containerName,
            command: ["hermes", "skills", "uninstall", ref],
            stdin: nil,
        )
        guard result.ok else {
            logger.error("hermes skills uninstall failed tenant=\(tenantID) exit=\(result.exitCode)")
            throw HTTPError(.badGateway, message: ErrorCode.uninstallFailed.rawValue)
        }
        logger.info("hermes skill uninstalled tenant=\(tenantID)")
        return await refreshedInstalled(handle: handle)
    }

    // MARK: - Helpers

    private func requireHandle(tenantID: UUID) async throws -> HermesContainerHandle {
        guard let handle = try await containerManager.handle(tenantID: tenantID) else {
            throw HTTPError(.conflict, message: ErrorCode.containerNotFound.rawValue)
        }
        return handle
    }

    private func refreshedInstalled(handle: HermesContainerHandle) async -> [PluginCatalogEntryDTO] {
        guard let baseURL = URL(string: handle.baseURL) else { return [] }
        return await installedSkillsClient.installedSkills(
            baseURL: baseURL,
            authHeader: "Bearer \(handle.apiServerKey)",
        )
    }

    /// Validate a skill reference before it becomes a `docker exec` argv element.
    /// `docker exec` takes an argv array (no shell), so shell-injection isn't
    /// possible, but we still reject empty/whitespace/control-char refs and
    /// leading `-` (so a ref can't be parsed as a CLI flag by `hermes`).
    static func validatedRef(_ raw: String) throws -> String {
        let ref = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ref.isEmpty, ref.count <= 512, !ref.hasPrefix("-") else {
            throw HTTPError(.badRequest, message: ErrorCode.invalidSkillRef.rawValue)
        }
        let bad = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
        guard ref.rangeOfCharacter(from: bad) == nil else {
            throw HTTPError(.badRequest, message: ErrorCode.invalidSkillRef.rawValue)
        }
        return ref
    }
}
