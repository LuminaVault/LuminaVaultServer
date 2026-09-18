import Foundation

/// The read-only workspace surface: what the agent's checkout looks like right
/// now, and what has changed in it.
///
/// Internal shapes, deliberately separate from the wire DTOs. The Hermes
/// dashboard's JSON is loose — fields appear and disappear across versions —
/// so parsing lands here first and the controller maps to a stable contract.
/// A client never sees an upstream field name.
///
/// Read-only on purpose. Staging, committing, pushing and opening pull
/// requests all exist on the same upstream API and are all deliberately absent:
/// they need an auth scope, an audit trail and a confirmation model of their
/// own before a browser session can reach them.
enum HermesWorkspace {
    /// One repository the agent can see.
    struct Repo: Sendable, Equatable {
        let root: String
        let branch: String?
        /// Detached HEAD, mid-rebase, and similar states the UI should not
        /// pretend are an ordinary branch.
        let isDetached: Bool
    }

    struct Branch: Sendable, Equatable {
        let name: String
        let isCurrent: Bool
    }

    struct Worktree: Sendable, Equatable {
        let path: String
        let branch: String?
        let isPrimary: Bool
    }

    /// A file with uncommitted changes.
    struct ChangedFile: Sendable, Equatable {
        let path: String
        let added: Int
        let removed: Int
        /// Upstream's own word for the change — `modified`, `added`,
        /// `deleted`, `renamed`, `untracked`. Passed through rather than
        /// mapped to an enum, because a new state should show as itself
        /// instead of collapsing into "modified".
        let status: String
    }

    /// A unified diff for one file, as text. Not parsed into hunks here: the
    /// client renders it, and parsing would mean inventing a hunk model that
    /// every consumer then has to agree with.
    struct FileDiff: Sendable, Equatable {
        let path: String
        let diff: String
        /// True when the diff was cut short by the body cap, so the UI can say
        /// so rather than showing a silently truncated file as complete.
        let truncated: Bool
    }
}
