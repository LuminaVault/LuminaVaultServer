import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import Logging
import SQLKit

/// One lint finding: a specific thing wrong with a specific document.
struct VaultLintFinding: Codable, Sendable {
    /// Vault-relative path, when the finding belongs to a document.
    let path: String?
    /// Line the problem sits on, when it is line-scoped (links).
    let line: Int?
    let message: String
}

/// One check's outcome. A check that finds nothing still reports, so the
/// caller can tell "clean" from "not run".
struct VaultLintCheck: Codable, Sendable {
    enum Severity: String, Codable, Sendable {
        /// Something is broken and retrieval is affected.
        case error
        /// Worth fixing; retrieval still works.
        case warning
        /// Nothing found.
        case pass
    }

    let name: String
    let severity: Severity
    let message: String
    let findings: [VaultLintFinding]
}

struct VaultLintReport: Codable, Sendable {
    let checks: [VaultLintCheck]
    let passed: Int
    let warned: Int
    let failed: Int
    /// True when any check is `warning` or `error`.
    let hasFindings: Bool
}

/// Read-only health checks over a tenant's vault and its index.
///
/// Ported from NexusOS's vault linter, which is the piece of that project
/// most directly useful to a human: it turns "my notes feel messy" into a
/// specific list of broken links, duplicate names, and orphaned documents.
///
/// Strictly read-only — it reads files but never rewrites them, and never
/// creates index state as a side effect. That matters because a linter that
/// silently "fixes" markdown is a linter you cannot run on someone's vault.
///
/// Two families of check:
///
/// - **Index-derived** (broken/ambiguous links, orphans, duplicate slugs,
///   stale index) read `vault_links`, `vault_files`, and `memory_chunks`. Cheap.
/// - **File-derived** (oversized, empty, unreadable, frontmatter) open the raw
///   files. Bounded by `maxFilesScanned` so a huge vault cannot turn one
///   request into a multi-minute disk walk.
struct VaultLintService: Sendable {
    let fluent: Fluent
    let vaultPaths: VaultPathService
    let links: VaultLinkRepository
    let status: VaultIndexStatusService
    let logger: Logger

    /// Files opened per run. Above this the file-derived checks report what
    /// they saw and say they were truncated rather than lying by omission.
    static let maxFilesScanned = 2000
    /// Findings listed per check; counts in the message stay exact.
    static let maxFindingsPerCheck = 50
    /// Files above this are flagged as oversized. Matches NexusOS's 5 MiB.
    static let oversizedBytes: Int64 = 5 * 1024 * 1024

    func lint(tenantID: UUID) async throws -> VaultLintReport {
        guard let sql = fluent.db() as? any SQLDatabase else {
            throw HTTPError(.internalServerError, message: "SQL driver required for lint")
        }

        var checks: [VaultLintCheck] = []
        checks.append(contentsOf: try await linkChecks(sql: sql, tenantID: tenantID))
        checks.append(try await duplicateSlugs(sql: sql, tenantID: tenantID))
        checks.append(try await orphans(tenantID: tenantID))
        checks.append(try await staleIndex(tenantID: tenantID))
        checks.append(contentsOf: try await fileChecks(sql: sql, tenantID: tenantID))

        return VaultLintReport(
            checks: checks,
            passed: checks.count { $0.severity == .pass },
            warned: checks.count { $0.severity == .warning },
            failed: checks.count { $0.severity == .error },
            hasFindings: checks.contains { $0.severity != .pass }
        )
    }

    // MARK: - Index-derived checks

    /// `broken-links` and `ambiguous-links`, from `vault_links`.
    private func linkChecks(sql: any SQLDatabase, tenantID: UUID) async throws -> [VaultLintCheck] {
        let rows = try await sql.raw("""
        SELECT source_path, source_line, raw_target, resolution_state
        FROM vault_links
        WHERE tenant_id = \(bind: tenantID) AND resolution_state <> \(bind: WikilinkResolutionState.resolved.rawValue)
        ORDER BY source_path NULLS LAST, source_line
        """).all(decoding: DanglingLinkRow.self)

        let broken = rows.filter { $0.resolution_state == WikilinkResolutionState.unresolved.rawValue }
        let ambiguous = rows.filter { $0.resolution_state == WikilinkResolutionState.ambiguous.rawValue }

        return [
            check(
                name: "broken-links",
                // A link to a note you have not written yet is intent, not
                // damage — warn, never error.
                severity: broken.isEmpty ? .pass : .warning,
                summary: broken.isEmpty
                    ? "no broken wiki links"
                    : "\(broken.count) link(s) point at a document that does not exist",
                findings: broken.map {
                    VaultLintFinding(path: $0.source_path, line: $0.source_line, message: "unresolved link [[\($0.raw_target)]]")
                }
            ),
            check(
                name: "ambiguous-links",
                severity: ambiguous.isEmpty ? .pass : .warning,
                summary: ambiguous.isEmpty
                    ? "no ambiguous wiki links"
                    : "\(ambiguous.count) link(s) match more than one document",
                findings: ambiguous.map {
                    VaultLintFinding(path: $0.source_path, line: $0.source_line, message: "ambiguous link [[\($0.raw_target)]] — use a full path")
                }
            ),
        ]
    }

    /// `duplicate-slugs` — two documents sharing a filename stem, which is
    /// exactly what makes `[[name]]` ambiguous.
    private func duplicateSlugs(sql: any SQLDatabase, tenantID: UUID) async throws -> VaultLintCheck {
        let paths = try await sql.raw("""
        SELECT path FROM vault_files WHERE tenant_id = \(bind: tenantID) ORDER BY path
        """).all(decoding: PathOnlyRow.self).map(\.path)

        var byStem: [String: [String]] = [:]
        for path in paths {
            byStem[WikilinkResolver.stem(of: path), default: []].append(path)
        }
        let duplicates = byStem.filter { $0.value.count > 1 }.sorted { $0.key < $1.key }

        return check(
            name: "duplicate-slugs",
            severity: duplicates.isEmpty ? .pass : .warning,
            summary: duplicates.isEmpty
                ? "no duplicate document names"
                : "\(duplicates.count) name(s) are used by more than one document",
            findings: duplicates.flatMap { stem, group in
                group.map {
                    VaultLintFinding(path: $0, line: nil, message: "name '\(stem)' also used by \(group.count - 1) other document(s)")
                }
            }
        )
    }

    /// `orphans` — documents nothing links to. Informational: a vault of
    /// unlinked captures is a perfectly valid way to work.
    private func orphans(tenantID: UUID) async throws -> VaultLintCheck {
        let paths = try await links.orphanPaths(tenantID: tenantID, limit: Self.maxFindingsPerCheck * 4)
        return check(
            name: "orphans",
            severity: paths.isEmpty ? .pass : .warning,
            summary: paths.isEmpty
                ? "every document is linked from somewhere"
                : "\(paths.count) document(s) have no incoming links",
            findings: paths.map { VaultLintFinding(path: $0, line: nil, message: "no other document links here") }
        )
    }

    /// `stale-index` — reuses the same computation `/v1/vault/index` reports,
    /// so lint and status can never disagree.
    private func staleIndex(tenantID: UUID) async throws -> VaultLintCheck {
        let indexStatus = try await status.status(tenantID: tenantID)
        let findings = (indexStatus.unindexedSample.map {
            VaultLintFinding(path: $0, line: nil, message: "not indexed — invisible to search")
        } + indexStatus.staleSample.map {
            VaultLintFinding(path: $0, line: nil, message: "changed since it was last indexed")
        })
        return VaultLintCheck(
            name: "stale-index",
            // Unlike the link checks, this one is an error: affected documents
            // are genuinely unreachable through citation-bearing search.
            severity: indexStatus.stale ? .error : .pass,
            message: indexStatus.stale ? indexStatus.staleReasons.joined(separator: "; ") : "index is fresh",
            findings: Array(findings.prefix(Self.maxFindingsPerCheck))
        )
    }

    // MARK: - File-derived checks

    /// `oversized-files`, `empty-documents`, and `unreadable-files` in one
    /// disk pass — opening each file three times would be wasteful and would
    /// let the three checks disagree about what they saw.
    private func fileChecks(sql: any SQLDatabase, tenantID: UUID) async throws -> [VaultLintCheck] {
        let files = try await sql.raw("""
        SELECT path, size_bytes FROM vault_files
        WHERE tenant_id = \(bind: tenantID)
        ORDER BY path
        LIMIT \(bind: Self.maxFilesScanned)
        """).all(decoding: FileRow.self)

        let rawRoot = vaultPaths.rawDirectory(for: tenantID)
        var oversized: [VaultLintFinding] = []
        var empty: [VaultLintFinding] = []
        var unreadable: [VaultLintFinding] = []

        for file in files {
            if file.size_bytes > Self.oversizedBytes {
                oversized.append(
                    VaultLintFinding(
                        path: file.path,
                        line: nil,
                        message: "\(file.size_bytes / (1024 * 1024)) MiB — chunking and embedding this is slow and expensive"
                    )
                )
                // Deliberately not opened: reading a file we already know is
                // huge is the exact cost this check exists to warn about.
                continue
            }

            // The stored path is not automatically trusted just because we
            // wrote it — same boundary check the vault read path uses.
            guard let url = try? VaultController.resolveInside(rawRoot: rawRoot, relative: file.path) else {
                unreadable.append(VaultLintFinding(path: file.path, line: nil, message: "path escapes the vault boundary"))
                continue
            }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                unreadable.append(VaultLintFinding(path: file.path, line: nil, message: "missing, unreadable, or not valid UTF-8"))
                continue
            }
            if MarkdownChunker.chunk(text).isEmpty {
                // Chunk-empty rather than byte-empty: a file of only
                // frontmatter or blank lines contributes nothing to search,
                // which is what actually matters here.
                empty.append(VaultLintFinding(path: file.path, line: nil, message: "no body content — nothing to retrieve"))
            }
        }

        let truncated = files.count >= Self.maxFilesScanned
        let suffix = truncated ? " (first \(Self.maxFilesScanned) documents only)" : ""

        return [
            check(
                name: "oversized-files",
                severity: oversized.isEmpty ? .pass : .warning,
                summary: oversized.isEmpty ? "no oversized files\(suffix)" : "\(oversized.count) file(s) over 5 MiB\(suffix)",
                findings: oversized
            ),
            check(
                name: "empty-documents",
                severity: empty.isEmpty ? .pass : .warning,
                summary: empty.isEmpty ? "no empty documents\(suffix)" : "\(empty.count) document(s) have no body content\(suffix)",
                findings: empty
            ),
            check(
                name: "unreadable-files",
                // Unreadable is an error: the row claims a document exists
                // that the vault cannot actually produce.
                severity: unreadable.isEmpty ? .pass : .error,
                summary: unreadable.isEmpty ? "all files readable\(suffix)" : "\(unreadable.count) file(s) could not be read\(suffix)",
                findings: unreadable
            ),
        ]
    }

    // MARK: - Helpers

    private func check(
        name: String,
        severity: VaultLintCheck.Severity,
        summary: String,
        findings: [VaultLintFinding]
    ) -> VaultLintCheck {
        VaultLintCheck(
            name: name,
            severity: severity,
            message: summary,
            findings: Array(findings.prefix(Self.maxFindingsPerCheck))
        )
    }
}

private struct DanglingLinkRow: Decodable {
    let source_path: String?
    let source_line: Int
    let raw_target: String
    let resolution_state: String
}

private struct PathOnlyRow: Decodable {
    let path: String
}

private struct FileRow: Decodable {
    let path: String
    let size_bytes: Int64
}
