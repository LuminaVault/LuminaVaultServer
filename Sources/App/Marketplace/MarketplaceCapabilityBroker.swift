import AsyncHTTPClient
import Crypto
import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import Logging
import LuminaVaultShared
import NIOCore

struct MarketplaceCapabilityRequest: Codable, Equatable {
    let id: String
    let operation: String
    let arguments: [String: String]
}

struct MarketplaceCapabilityResult: Codable, Equatable {
    let id: String
    let ok: Bool
    let values: [String: String]
    let error: String?
}

protocol MarketplaceCapabilityBrokering: Sendable {
    func execute(
        _ requests: [MarketplaceCapabilityRequest],
        tenantID: UUID,
        pluginSlug: String,
        permissions: Set<PluginPermission>,
        networkHosts: Set<String>
    ) async -> [MarketplaceCapabilityResult]
}

struct DisabledMarketplaceCapabilityBroker: MarketplaceCapabilityBrokering {
    func execute(
        _ requests: [MarketplaceCapabilityRequest],
        tenantID _: UUID,
        pluginSlug _: String,
        permissions _: Set<PluginPermission>,
        networkHosts _: Set<String>
    ) async -> [MarketplaceCapabilityResult] {
        requests.map { .init(id: $0.id, ok: false, values: [:], error: "capability_broker_disabled") }
    }
}

struct MarketplaceCapabilityBroker: MarketplaceCapabilityBrokering {
    static let maxRequests = 16
    static let maxValueBytes = 1_048_576

    let fluent: Fluent
    let vaultPaths: VaultPathService
    let logger: Logger
    let ssrfGuard: SSRFGuard
    let httpClient: HTTPClient

    init(
        fluent: Fluent,
        vaultPaths: VaultPathService,
        logger: Logger,
        ssrfGuard: SSRFGuard = .init(allowPrivateRanges: false, requireHTTPS: true),
        httpClient: HTTPClient = BYOHTTP.httpClient
    ) {
        self.fluent = fluent
        self.vaultPaths = vaultPaths
        self.logger = logger
        self.ssrfGuard = ssrfGuard
        self.httpClient = httpClient
    }

    func execute(
        _ requests: [MarketplaceCapabilityRequest],
        tenantID: UUID,
        pluginSlug: String,
        permissions: Set<PluginPermission>,
        networkHosts: Set<String>
    ) async -> [MarketplaceCapabilityResult] {
        guard requests.count <= Self.maxRequests else {
            return requests.map { .init(id: $0.id, ok: false, values: [:], error: "too_many_capability_requests") }
        }
        var results: [MarketplaceCapabilityResult] = []
        results.reserveCapacity(requests.count)
        for request in requests {
            do {
                let values = try await executeOne(
                    request, tenantID: tenantID, pluginSlug: pluginSlug,
                    permissions: permissions, networkHosts: networkHosts
                )
                results.append(.init(id: request.id, ok: true, values: values, error: nil))
            } catch let error as BrokerError {
                results.append(.init(id: request.id, ok: false, values: [:], error: error.rawValue))
            } catch {
                logger.warning(
                    "marketplace capability failed",
                    metadata: ["operation": "\(request.operation)", "plugin": "\(pluginSlug)"]
                )
                results.append(.init(id: request.id, ok: false, values: [:], error: "capability_failed"))
            }
        }
        return results
    }

    private func executeOne(
        _ request: MarketplaceCapabilityRequest,
        tenantID: UUID,
        pluginSlug: String,
        permissions: Set<PluginPermission>,
        networkHosts: Set<String>
    ) async throws -> [String: String] {
        switch request.operation {
        case PluginPermission.memoryRead.rawValue:
            try require(.memoryRead, in: permissions)
            return try await readMemory(request.arguments, tenantID: tenantID)
        case PluginPermission.memoryWrite.rawValue:
            try require(.memoryWrite, in: permissions)
            return try await writeMemory(request.arguments, tenantID: tenantID, pluginSlug: pluginSlug)
        case PluginPermission.vaultRead.rawValue:
            try require(.vaultRead, in: permissions)
            return try await readVault(request.arguments, tenantID: tenantID)
        case PluginPermission.vaultWrite.rawValue:
            try require(.vaultWrite, in: permissions)
            return try await writeVault(request.arguments, tenantID: tenantID)
        case PluginPermission.networkFetch.rawValue:
            try require(.networkFetch, in: permissions)
            return try await fetchNetwork(request.arguments, allowedHosts: networkHosts)
        case PluginPermission.outputEmit.rawValue:
            try require(.outputEmit, in: permissions)
            return request.arguments
        default:
            throw BrokerError.operationUnsupported
        }
    }

    private func readMemory(_ arguments: [String: String], tenantID: UUID) async throws -> [String: String] {
        guard let rawID = arguments["id"], let id = UUID(uuidString: rawID) else { throw BrokerError.invalidArguments }
        guard let row = try await Memory.query(on: fluent.db(), tenantID: tenantID)
            .filter(\.$id == id).first()
        else { throw BrokerError.resourceNotFound }
        guard row.content.utf8.count <= Self.maxValueBytes else { throw BrokerError.responseTooLarge }
        return [
            "id": id.uuidString,
            "content": row.content,
            "tags": (row.tags ?? []).joined(separator: ","),
        ]
    }

    private func writeMemory(
        _ arguments: [String: String], tenantID: UUID, pluginSlug: String
    ) async throws -> [String: String] {
        guard let content = arguments["content"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !content.isEmpty, content.utf8.count <= 65536
        else { throw BrokerError.invalidArguments }
        let tags = arguments["tags"]?.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard tags?.count ?? 0 <= 32,
              tags?.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 64 }) ?? true
        else { throw BrokerError.invalidArguments }
        let row = Memory(
            tenantID: tenantID, content: content, tags: tags,
            originKind: MemorySourceKindDTO.import.rawValue,
            originSourceID: "marketplace:\(pluginSlug)"
        )
        try await row.create(on: fluent.db())
        return try ["id": row.requireID().uuidString]
    }

    private func readVault(_ arguments: [String: String], tenantID: UUID) async throws -> [String: String] {
        let path = try safeRelativePath(arguments["path"])
        guard let row = try await VaultFile.query(on: fluent.db(), tenantID: tenantID)
            .filter(\.$path == path).first()
        else { throw BrokerError.resourceNotFound }
        let target = try resolveVaultPath(path, tenantID: tenantID)
        let data = try Data(contentsOf: target, options: .mappedIfSafe)
        guard data.count <= Self.maxValueBytes else { throw BrokerError.responseTooLarge }
        return [
            "path": path, "contentType": row.contentType,
            "bytesBase64": data.base64EncodedString(), "sha256": row.sha256,
        ]
    }

    private func writeVault(_ arguments: [String: String], tenantID: UUID) async throws -> [String: String] {
        let path = try safeRelativePath(arguments["path"])
        let data: Data
        if let encoded = arguments["bytesBase64"], let decoded = Data(base64Encoded: encoded) {
            data = decoded
        } else if let text = arguments["text"] {
            data = Data(text.utf8)
        } else {
            throw BrokerError.invalidArguments
        }
        guard !data.isEmpty, data.count <= Self.maxValueBytes else { throw BrokerError.invalidArguments }
        try vaultPaths.ensureTenantDirectories(for: tenantID)
        let target = try resolveVaultPath(path, tenantID: tenantID)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target, options: .atomic)
        let sha256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let contentType = arguments["contentType"] ?? "application/octet-stream"
        guard contentType.utf8.count <= 255,
              contentType.range(of: "^[a-zA-Z0-9][a-zA-Z0-9.+-]*/[a-zA-Z0-9][a-zA-Z0-9.+-]*$", options: .regularExpression) != nil
        else { throw BrokerError.invalidArguments }
        let row = try await VaultFile.query(on: fluent.db(), tenantID: tenantID)
            .filter(\.$path == path).first() ?? VaultFile(
                tenantID: tenantID, path: path, contentType: contentType,
                sizeBytes: Int64(data.count), sha256: sha256
            )
        row.contentType = contentType
        row.sizeBytes = Int64(data.count)
        row.sha256 = sha256
        try await row.save(on: fluent.db())
        return ["path": path, "sha256": sha256, "sizeBytes": String(data.count)]
    }

    private func fetchNetwork(
        _ arguments: [String: String], allowedHosts: Set<String>
    ) async throws -> [String: String] {
        guard let rawURL = arguments["url"] else { throw BrokerError.invalidArguments }
        let url = try await ssrfGuard.validate(rawURL: rawURL)
        guard url.user == nil, url.password == nil, url.port == nil || url.port == 443 else {
            throw BrokerError.invalidArguments
        }
        guard let host = url.host?.lowercased(), allowedHosts.contains(host) else { throw BrokerError.hostNotAllowed }
        var request = HTTPClientRequest(url: url.absoluteString)
        request.method = .GET
        request.headers.add(name: "Accept", value: "application/json, text/plain;q=0.9, */*;q=0.1")
        let response = try await httpClient.execute(request, timeout: .seconds(10))
        guard (200 ..< 300).contains(Int(response.status.code)) else { throw BrokerError.upstreamFailure }
        var body = try await response.body.collect(upTo: Self.maxValueBytes)
        let data = body.readData(length: body.readableBytes) ?? Data()
        return [
            "status": String(response.status.code),
            "contentType": response.headers.first(name: "content-type") ?? "application/octet-stream",
            "bytesBase64": data.base64EncodedString(),
        ]
    }

    private func require(_ permission: PluginPermission, in permissions: Set<PluginPermission>) throws {
        guard permissions.contains(permission) else { throw BrokerError.permissionDenied }
    }

    private func safeRelativePath(_ raw: String?) throws -> String {
        guard let raw else { throw BrokerError.invalidArguments }
        let normalized = raw.replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let segments = normalized.split(separator: "/", omittingEmptySubsequences: false)
        guard !normalized.isEmpty, normalized.utf8.count <= 512,
              !segments.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
              normalized.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else { throw BrokerError.invalidArguments }
        return normalized
    }

    private func resolveVaultPath(_ path: String, tenantID: UUID) throws -> URL {
        let root = vaultPaths.rawDirectory(for: tenantID).resolvingSymlinksInPath().standardizedFileURL
        let target = root.appendingPathComponent(path)
        let resolved = target.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.path.hasPrefix(root.path + "/") else { throw BrokerError.invalidArguments }
        return target
    }
}

private enum BrokerError: String, Error {
    case permissionDenied = "permission_denied"
    case invalidArguments = "invalid_arguments"
    case operationUnsupported = "operation_unsupported"
    case resourceNotFound = "resource_not_found"
    case responseTooLarge = "response_too_large"
    case hostNotAllowed = "host_not_allowed"
    case upstreamFailure = "upstream_failure"
}
