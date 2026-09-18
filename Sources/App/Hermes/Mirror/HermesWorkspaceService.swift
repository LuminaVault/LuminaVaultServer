import Foundation
import LuminaVaultShared

/// Reads the agent's checkout: the file tree, the branch, and what has changed.
///
/// A thin proxy on purpose. The Hermes dashboard already computes all of this,
/// and reimplementing git here would mean a second answer that can disagree
/// with the one the agent itself sees.
///
/// Every method is a read. The upstream API also stages, commits, pushes and
/// opens pull requests; none of that is reachable through here, and adding it
/// is a deliberate design task rather than another passthrough — a browser
/// session should not be able to push on the user's behalf without an auth
/// scope, an audit trail and a confirmation step.
extension HermesMirrorService {
    /// Only a remote Hermes has a checkout to inspect. The filesystem
    /// transport mirrors files the server already owns, so there is no repo
    /// behind it and saying "unsupported" is more honest than an empty result.
    private func requireDashboard(tenantID: UUID) async throws -> HermesDashboardClient {
        let transport = try await transports.transport(tenantID: tenantID)
        guard let remote = transport as? RemoteHermesTransport,
              let dashboard = remote.dashboard
        else {
            throw HermesMirrorTransportError.unsupported("workspace")
        }
        return dashboard
    }

    /// Repo, branches, worktrees and changed files in one call.
    ///
    /// Four upstream requests fetched concurrently rather than in sequence:
    /// the pane needs all four before it can render anything, and serially
    /// they would stack four round trips to a box that may be across a
    /// tailnet.
    func workspaceStatus(tenantID: UUID, path: String) async throws -> HermesWorkspaceStatusDTO {
        let dashboard = try await requireDashboard(tenantID: tenantID)
        async let repo = dashboard.gitStatus(path: path)
        async let branches = dashboard.gitBranches(path: path)
        async let worktrees = dashboard.gitWorktrees(path: path)
        async let changes = dashboard.gitChangedFiles(path: path)

        return try await HermesWorkspaceStatusDTO(
            repo: HermesWorkspaceRepoDTO(
                root: repo.root,
                branch: repo.branch,
                isDetached: repo.isDetached
            ),
            branches: branches.map {
                HermesWorkspaceBranchDTO(name: $0.name, isCurrent: $0.isCurrent)
            },
            worktrees: worktrees.map {
                HermesWorkspaceWorktreeDTO(path: $0.path, branch: $0.branch, isPrimary: $0.isPrimary)
            },
            changes: changes.map {
                HermesWorkspaceChangeDTO(
                    path: $0.path,
                    added: $0.added,
                    removed: $0.removed,
                    status: $0.status
                )
            }
        )
    }

    func workspaceDiff(tenantID: UUID, repoPath: String, file: String) async throws -> HermesWorkspaceDiffDTO {
        let dashboard = try await requireDashboard(tenantID: tenantID)
        let diff = try await dashboard.gitFileDiff(repoPath: repoPath, file: file)
        return HermesWorkspaceDiffDTO(path: diff.path, diff: diff.diff, truncated: diff.truncated)
    }

    func workspaceListing(tenantID: UUID, path: String) async throws -> HermesWorkspaceListingDTO {
        let dashboard = try await requireDashboard(tenantID: tenantID)
        let entries = try await dashboard.listFiles(path: path)
        return HermesWorkspaceListingDTO(
            path: path,
            entries: entries.map {
                HermesWorkspaceFileEntryDTO(name: $0.name, path: $0.path, isDirectory: $0.isDirectory)
            }
        )
    }

    func workspaceFile(tenantID: UUID, path: String) async throws -> HermesWorkspaceFileDTO {
        let dashboard = try await requireDashboard(tenantID: tenantID)
        let content = try await dashboard.readText(path: path)
        return HermesWorkspaceFileDTO(path: path, content: content, truncated: false)
    }
}
