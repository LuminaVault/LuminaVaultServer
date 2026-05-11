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

    /// HER-168: per-tenant vault skill directory. Layout is
    /// `<rootPath>/tenants/<tenantID>/skills/<name>/SKILL.md`. The catalog
    /// scans this on every load so users can add or remove skills
    /// without restarting the server.
    func skillsDirectory(for tenantID: UUID) -> URL {
        tenantRoot(for: tenantID).appendingPathComponent("skills")
    }

    func ensureTenantDirectories(for tenantID: UUID) throws {
        let raw = rawDirectory(for: tenantID)
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
    }
}
