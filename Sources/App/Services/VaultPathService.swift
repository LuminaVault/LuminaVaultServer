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

    func ensureTenantDirectories(for tenantID: UUID) throws {
        let raw = rawDirectory(for: tenantID)
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
    }
}
