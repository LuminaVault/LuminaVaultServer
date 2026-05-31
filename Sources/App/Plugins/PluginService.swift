import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import Logging
import LuminaVaultShared

/// HER-43 (Slice 1) — install lifecycle + connector sync for declarative
/// plugins. Reads the static `PluginCatalog`, seals install config via
/// `SecretBox`, and runs connector syncs through the existing
/// `ImportService.importLinks` pipeline. All install queries are tenant-scoped
/// (`PluginInstall: TenantModel`); plaintext config is never returned.
struct PluginService {
    let fluent: Fluent
    let secretBox: SecretBox
    let importService: ImportService
    let connectors: ConnectorRegistry
    let logger: Logger

    enum ErrorCode: String {
        case unknownPlugin = "unknown_plugin"
        case missingField = "missing_field"
        case invalidField = "invalid_field"
        case unknownField = "unknown_field"
        case installNotFound = "install_not_found"
        case notAConnector = "not_a_connector"
        case connectorUnavailable = "connector_unavailable"
        case connectorUnauthorized = "connector_unauthorized"
        case connectorUpstream = "connector_upstream_failure"
        case encryptionFailed = "encryption_failed"
        case disabled = "install_disabled"
    }

    // MARK: - Catalog

    func listCatalog(category: PluginCategory?) -> [PluginCatalogEntryDTO] {
        PluginCatalog.catalog(category: category)
    }

    // MARK: - Installs

    func listInstalls(tenantID: UUID) async throws -> [PluginInstallDTO] {
        let rows = try await PluginInstall.query(on: fluent.db())
            .filter(\.$tenantID == tenantID)
            .sort(\.$createdAt, .ascending)
            .all()
        return try rows.map(Self.dto)
    }

    func install(tenantID: UUID, slug: String, config: [String: String]) async throws -> PluginInstallDTO {
        try validate(slug: slug, config: config)
        let sealed = try seal(config, tenantID: tenantID)

        let existing = try await loadInstall(tenantID: tenantID, slug: slug)
        let row: PluginInstall = if let existing {
            existing
        } else {
            PluginInstall(
                tenantID: tenantID, pluginSlug: slug,
                configCiphertext: sealed.ciphertext, configNonce: sealed.nonce,
            )
        }
        row.configCiphertext = sealed.ciphertext
        row.configNonce = sealed.nonce
        row.status = PluginInstallState.enabled
        try await row.save(on: fluent.db())
        logger.info("plugin installed tenant=\(tenantID) slug=\(slug)")
        return try Self.dto(row)
    }

    func update(
        tenantID: UUID,
        installID: UUID,
        config: [String: String]?,
        status: PluginInstallStatus?,
    ) async throws -> PluginInstallDTO {
        let row = try await requireInstall(tenantID: tenantID, installID: installID)
        if let config {
            try validate(slug: row.pluginSlug, config: config)
            let sealed = try seal(config, tenantID: tenantID)
            row.configCiphertext = sealed.ciphertext
            row.configNonce = sealed.nonce
        }
        if let status {
            row.status = status.rawValue
        }
        try await row.save(on: fluent.db())
        return try Self.dto(row)
    }

    func uninstall(tenantID: UUID, installID: UUID) async throws {
        let row = try await requireInstall(tenantID: tenantID, installID: installID)
        try await row.delete(on: fluent.db())
    }

    // MARK: - Sync (connector capability)

    func sync(tenantID: UUID, installID: UUID) async throws -> PluginSyncResponse {
        let row = try await requireInstall(tenantID: tenantID, installID: installID)
        guard row.status == PluginInstallState.enabled else {
            throw HTTPError(.conflict, message: ErrorCode.disabled.rawValue)
        }
        guard let entry = PluginCatalog.entry(slug: row.pluginSlug) else {
            throw HTTPError(.notFound, message: ErrorCode.unknownPlugin.rawValue)
        }
        guard entry.dto.capabilityKind == .connector else {
            throw HTTPError(.badRequest, message: ErrorCode.notAConnector.rawValue)
        }
        guard let connector = connectors.connector(binding: entry.binding) else {
            throw HTTPError(.serviceUnavailable, message: ErrorCode.connectorUnavailable.rawValue)
        }

        let config = try openConfig(row, tenantID: tenantID)
        let urls: [String]
        do {
            urls = try await connector.fetchURLs(config: config, tenantID: tenantID)
        } catch let ConnectorError.missingConfig(key) {
            throw HTTPError(.badRequest, message: "\(ErrorCode.missingField.rawValue):\(key)")
        } catch let ConnectorError.invalidConfig(key) {
            throw HTTPError(.badRequest, message: "\(ErrorCode.invalidField.rawValue):\(key)")
        } catch ConnectorError.unauthorized {
            throw HTTPError(.badGateway, message: ErrorCode.connectorUnauthorized.rawValue)
        } catch ConnectorError.upstreamFailure {
            throw HTTPError(.badGateway, message: ErrorCode.connectorUpstream.rawValue)
        }

        let result = try await importService.importLinks(
            tenantID: tenantID,
            sourceType: "connector:\(row.pluginSlug)",
            urls: Array(urls.prefix(ImportService.maxBatch)),
        )

        row.lastSyncAt = Date()
        try await row.save(on: fluent.db())

        return try PluginSyncResponse(
            installId: row.requireID(),
            sessionId: result.sessionID,
            status: ImportStatus.enriching,
            total: result.total,
            staged: result.staged,
            skipped: result.skipped,
        )
    }

    // MARK: - Helpers

    private func validate(slug: String, config: [String: String]) throws {
        switch PluginCatalog.validate(slug: slug, config: config) {
        case .ok: break
        case .unknownPlugin:
            throw HTTPError(.notFound, message: ErrorCode.unknownPlugin.rawValue)
        case let .missing(key):
            throw HTTPError(.badRequest, message: "\(ErrorCode.missingField.rawValue):\(key)")
        case let .unknownField(key):
            throw HTTPError(.badRequest, message: "\(ErrorCode.unknownField.rawValue):\(key)")
        }
    }

    private func seal(_ config: [String: String], tenantID: UUID) throws -> SecretBox.Sealed {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let plaintext = try String(decoding: encoder.encode(config), as: UTF8.self)
        do {
            return try secretBox.seal(plaintext, tenantID: tenantID)
        } catch {
            logger.error("plugin config encryption failed: \(error)")
            throw HTTPError(.internalServerError, message: ErrorCode.encryptionFailed.rawValue)
        }
    }

    private func openConfig(_ row: PluginInstall, tenantID: UUID) throws -> [String: String] {
        let sealed = SecretBox.Sealed(ciphertext: row.configCiphertext, nonce: row.configNonce)
        let plaintext = try secretBox.open(sealed, tenantID: tenantID)
        return (try? JSONDecoder().decode([String: String].self, from: Data(plaintext.utf8))) ?? [:]
    }

    private func loadInstall(tenantID: UUID, slug: String) async throws -> PluginInstall? {
        try await PluginInstall.query(on: fluent.db())
            .filter(\.$tenantID == tenantID)
            .filter(\.$pluginSlug == slug)
            .first()
    }

    private func requireInstall(tenantID: UUID, installID: UUID) async throws -> PluginInstall {
        guard let row = try await PluginInstall.query(on: fluent.db())
            .filter(\.$tenantID == tenantID)
            .filter(\.$id == installID)
            .first()
        else { throw HTTPError(.notFound, message: ErrorCode.installNotFound.rawValue) }
        return row
    }

    static func dto(_ row: PluginInstall) throws -> PluginInstallDTO {
        try PluginInstallDTO(
            id: row.requireID(),
            pluginSlug: row.pluginSlug,
            status: PluginInstallStatus(rawValue: row.status) ?? .enabled,
            hasConfig: !row.configCiphertext.isEmpty,
            createdAt: row.createdAt,
            lastSyncAt: row.lastSyncAt,
        )
    }
}
