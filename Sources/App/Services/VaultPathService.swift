import Foundation

struct VaultPathService {
    let rootPath: String

    func tenantRoot(for tenantID: UUID) -> URL {
        URL(fileURLWithPath: rootPath)
            .appendingPathComponent("tenants")
            .appendingPathComponent(tenantID.uuidString)
    }

    func rawDirectory(for tenantID: UUID) -> URL {
        tenantRoot(for: tenantID).appendingPathComponent("raw")
    }

    /// HER-35 — wiki articles compiled from `raw/` notes land here. One
    /// markdown file per concept, owned by the KB compile pipeline.
    func wikiDirectory(for tenantID: UUID) -> URL {
        tenantRoot(for: tenantID).appendingPathComponent("wiki")
    }

    /// HER-35 — long-form distilled memory artifacts (Synth-27 outputs,
    /// belief snapshots, weekly digests) land here.
    func memoriesDirectory(for tenantID: UUID) -> URL {
        tenantRoot(for: tenantID).appendingPathComponent("memories")
    }

    func ensureTenantDirectories(for tenantID: UUID) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: rawDirectory(for: tenantID), withIntermediateDirectories: true)
        try fm.createDirectory(at: wikiDirectory(for: tenantID), withIntermediateDirectories: true)
        try fm.createDirectory(at: memoriesDirectory(for: tenantID), withIntermediateDirectories: true)
    }
}
