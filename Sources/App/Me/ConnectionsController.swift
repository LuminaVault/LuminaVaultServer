import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import Logging
import LuminaVaultShared

extension ConnectionsSummaryResponse: @retroactive ResponseEncodable {}
extension ConnectionsTestAllResponse: @retroactive ResponseEncodable {}
extension ConnectionDiagnosticEventsResponse: @retroactive ResponseEncodable {}

/// Unified, task-based connection surface for Settings. It aggregates the
/// existing provider, Hermes, gateway, account, calendar, and plugin state into
/// one stable response so clients do not re-implement status inference.
struct ConnectionsController {
    let fluent: Fluent
    let logger: Logger

    private static let maxEventsLimit = 100
    private static let defaultEventsLimit = 30

    func addRoutes(to router: RouterGroup<AppRequestContext>) {
        router.get(use: summary)
        router.post("test-all", use: testAll)
        router.get("events", use: events)
    }

    // MARK: - GET /v1/me/connections

    @Sendable
    func summary(_: Request, ctx: AppRequestContext) async throws -> ConnectionsSummaryResponse {
        let tenantID = try ctx.requireTenantID()
        let connections = try await buildSummaries(tenantID: tenantID)
        return ConnectionsSummaryResponse(connections: connections, checkedAt: Date())
    }

    // MARK: - POST /v1/me/connections/test-all

    @Sendable
    func testAll(_: Request, ctx: AppRequestContext) async throws -> ConnectionsTestAllResponse {
        let tenantID = try ctx.requireTenantID()
        let checkedAt = Date()
        let summaries = try await buildSummaries(tenantID: tenantID)
        let results = summaries.map { summary in
            ConnectionTestResultDTO(
                id: summary.id,
                kind: summary.kind,
                title: summary.title,
                health: summary.health,
                ok: summary.health == .connected,
                checkedAt: checkedAt,
                statusDetail: summary.statusDetail ?? Self.defaultStatusDetail(for: summary.health),
                errorCode: summary.health == .error ? "connection_error" : nil,
                errorMessage: summary.health == .error ? (summary.statusDetail ?? "Connection failed.") : nil
            )
        }

        for result in results {
            try await recordEvent(result: result, tenantID: tenantID, occurredAt: checkedAt)
        }

        return ConnectionsTestAllResponse(results: results, checkedAt: checkedAt)
    }

    // MARK: - GET /v1/me/connections/events

    @Sendable
    func events(_ req: Request, ctx: AppRequestContext) async throws -> ConnectionDiagnosticEventsResponse {
        let tenantID = try ctx.requireTenantID()
        let limit = Self.parseEventsLimit(req)
        let rows = try await ConnectionDiagnosticEvent.query(on: fluent.db())
            .filter(\.$tenantID == tenantID)
            .sort(\.$occurredAt, .descending)
            .limit(limit)
            .all()
        return ConnectionDiagnosticEventsResponse(
            events: rows.compactMap(Self.eventDTO),
            nextCursor: nil
        )
    }

    // MARK: - Summary Builder

    private func buildSummaries(tenantID: UUID) async throws -> [ConnectionSummaryDTO] {
        let db = fluent.db()

        let providerRows = try await UserProviderCredential.query(on: db)
            .filter(\.$tenantID == tenantID)
            .all()
        let gatewayRows = try await UserHermesGateway.query(on: db)
            .filter(\.$tenantID == tenantID)
            .all()
        let hermesConfig = try await UserHermesConfig.query(on: db)
            .filter(\.$tenantID == tenantID)
            .first()
        let calendarAccount = try await CalendarAccount.query(on: db)
            .filter(\.$tenantID == tenantID)
            .filter(\.$provider == "google")
            .first()
        let hermesContainer = try await HermesTenantContainer.query(on: db)
            .filter(\.$tenantID == tenantID)
            .first()
        let pluginInstalls = try await PluginInstall.query(on: db)
            .filter(\.$tenantID == tenantID)
            .all()

        var connections: [ConnectionSummaryDTO] = [
            apiConnection(),
            hermesServerConnection(row: hermesConfig),
            calendarConnection(row: calendarAccount),
            grokLinkedAccountConnection(container: hermesContainer),
            nousPortalConnection(container: hermesContainer),
        ]

        let providersByKind = Dictionary(
            providerRows.map { ($0.provider, $0) },
            uniquingKeysWith: { current, _ in current }
        )
        connections.append(contentsOf: ProviderID.allCases.map { providerConnection($0, row: providersByKind[providerKind(for: $0).rawValue]) })

        let gatewaysByID = Dictionary(
            gatewayRows.map { ($0.gatewayID, $0) },
            uniquingKeysWith: { current, _ in current }
        )
        connections.append(contentsOf: HermesGatewayID.allCases.map { gatewayConnection($0, row: gatewaysByID[$0.rawValue]) })

        connections.append(contentsOf: pluginInstalls.map(pluginConnection))
        return connections
    }

    private func apiConnection() -> ConnectionSummaryDTO {
        ConnectionSummaryDTO(
            id: "server:api",
            kind: .server,
            title: "LuminaVault API",
            subtitle: "Current authenticated backend",
            health: .connected,
            lastCheckedAt: Date(),
            statusDetail: "Reachable",
            actionHint: .openServerSettings
        )
    }

    private func hermesServerConnection(row: UserHermesConfig?) -> ConnectionSummaryDTO {
        guard let row else {
            return ConnectionSummaryDTO(
                id: "hermes:managed",
                kind: .hermesServer,
                title: "Hermes Server",
                subtitle: "Managed default",
                health: .connected,
                statusDetail: "Using managed Hermes",
                actionHint: .configureHermes
            )
        }

        let health = health(configured: true, verifiedAt: row.verifiedAt, lastFailureAt: nil)
        return ConnectionSummaryDTO(
            id: "hermes:byo",
            kind: .hermesServer,
            title: row.name ?? "Hermes Server",
            subtitle: row.baseURL,
            health: health,
            lastCheckedAt: row.verifiedAt,
            statusDetail: Self.defaultStatusDetail(for: health),
            actionHint: .configureHermes
        )
    }

    private func calendarConnection(row: CalendarAccount?) -> ConnectionSummaryDTO {
        guard let row else {
            return ConnectionSummaryDTO(
                id: "calendar:google",
                kind: .calendar,
                title: "Google Calendar",
                subtitle: "Schedule context",
                health: .needsSetup,
                statusDetail: "Not connected",
                actionHint: .connectAccount
            )
        }
        let health: ConnectionHealth = row.status == "needs_reauth" ? .error : .connected
        return ConnectionSummaryDTO(
            id: "calendar:google",
            kind: .calendar,
            title: "Google Calendar",
            subtitle: row.accountEmail,
            health: health,
            lastCheckedAt: row.lastSyncedAt,
            statusDetail: row.lastFailureCode ?? Self.defaultStatusDetail(for: health),
            actionHint: .connectAccount
        )
    }

    private func grokLinkedAccountConnection(container: HermesTenantContainer?) -> ConnectionSummaryDTO {
        let connectedAt = container?.xaiConnectedAt
        return ConnectionSummaryDTO(
            id: "linked:xai",
            kind: .linkedAccount,
            title: "Grok",
            subtitle: "xAI OAuth account",
            health: connectedAt == nil ? .needsSetup : .connected,
            lastCheckedAt: connectedAt,
            statusDetail: connectedAt == nil ? "Not connected" : "Connected",
            actionHint: .connectAccount
        )
    }

    private func nousPortalConnection(container: HermesTenantContainer?) -> ConnectionSummaryDTO {
        let connectedAt = container?.nousConnectedAt
        return ConnectionSummaryDTO(
            id: "nous:portal",
            kind: .nous,
            title: "Nous Portal",
            subtitle: "Personal Nous subscription",
            health: connectedAt == nil ? .needsSetup : .connected,
            lastCheckedAt: connectedAt,
            statusDetail: connectedAt == nil ? "Not connected" : "Connected",
            actionHint: .connectAccount
        )
    }

    private func providerConnection(_ provider: ProviderID, row: UserProviderCredential?) -> ConnectionSummaryDTO {
        let kind = row.flatMap { ProviderCredentialKind(rawValue: $0.credentialKind) } ?? defaultCredentialKind(for: provider)
        let hasCredential = row.map { ($0.ciphertext != nil) || ($0.baseURL != nil) || (kind == .oauth) } ?? false
        let health = health(configured: hasCredential, verifiedAt: row?.verifiedAt, lastFailureAt: row?.lastFailureAt)
        return ConnectionSummaryDTO(
            id: "provider:\(provider.rawValue)",
            kind: .llmProvider,
            title: providerDisplayName(provider),
            subtitle: providerSubtitle(provider, kind: kind, row: row),
            health: health,
            providerID: provider,
            lastCheckedAt: row?.verifiedAt ?? row?.lastFailureAt,
            statusDetail: row?.lastFailureCode ?? Self.defaultStatusDetail(for: health),
            actionHint: .configureProvider
        )
    }

    private func gatewayConnection(_ gateway: HermesGatewayID, row: UserHermesGateway?) -> ConnectionSummaryDTO {
        let catalog = HermesGatewayCatalog.entry(for: gateway)
        let status = row.flatMap { HermesGatewayStatus(rawValue: $0.status) } ?? .notConfigured
        let health = gatewayHealth(status: status, row: row)
        return ConnectionSummaryDTO(
            id: "gateway:\(gateway.rawValue)",
            kind: .hermesGateway,
            title: catalog.displayName,
            subtitle: catalog.description,
            health: health,
            gatewayID: gateway,
            lastCheckedAt: row?.verifiedAt ?? row?.lastFailureAt,
            statusDetail: row?.lastFailureCode ?? Self.defaultStatusDetail(for: health),
            actionHint: .configureGateway
        )
    }

    private func pluginConnection(_ install: PluginInstall) -> ConnectionSummaryDTO {
        ConnectionSummaryDTO(
            id: "plugin:\(install.pluginSlug)",
            kind: .plugin,
            title: install.pluginSlug,
            subtitle: install.status == PluginInstallState.enabled ? "Plugin enabled" : "Plugin disabled",
            health: install.status == PluginInstallState.enabled ? .connected : .degraded,
            lastCheckedAt: install.lastSyncAt,
            statusDetail: install.status,
            actionHint: .openPlugin
        )
    }

    // MARK: - Diagnostics

    private func recordEvent(result: ConnectionTestResultDTO, tenantID: UUID, occurredAt: Date) async throws {
        let event = ConnectionDiagnosticEvent()
        event.tenantID = tenantID
        event.occurredAt = occurredAt
        event.kind = result.kind.rawValue
        event.connectionID = result.id
        event.connectionTitle = result.title
        event.severity = severity(for: result.health).rawValue
        event.message = "\(result.title): \(result.statusDetail ?? Self.defaultStatusDetail(for: result.health))"
        event.code = result.errorCode
        try await event.save(on: fluent.db())
    }

    private static func eventDTO(_ row: ConnectionDiagnosticEvent) -> ConnectionDiagnosticEventDTO? {
        guard let kind = ConnectionKind(rawValue: row.kind),
              let severity = ConnectionDiagnosticSeverity(rawValue: row.severity)
        else { return nil }
        return ConnectionDiagnosticEventDTO(
            id: row.id ?? UUID(),
            occurredAt: row.occurredAt,
            kind: kind,
            connectionID: row.connectionID,
            connectionTitle: row.connectionTitle,
            severity: severity,
            message: row.message,
            code: row.code
        )
    }

    // MARK: - Helpers

    private func health(configured: Bool, verifiedAt: Date?, lastFailureAt: Date?) -> ConnectionHealth {
        guard configured else { return .needsSetup }
        if let lastFailureAt, verifiedAt.map({ lastFailureAt > $0 }) ?? true {
            return .error
        }
        if verifiedAt != nil {
            return .connected
        }
        return .degraded
    }

    private func gatewayHealth(status: HermesGatewayStatus, row: UserHermesGateway?) -> ConnectionHealth {
        switch status {
        case .notConfigured:
            return .needsSetup
        case .verified:
            return .connected
        case .configured:
            return health(configured: true, verifiedAt: row?.verifiedAt, lastFailureAt: row?.lastFailureAt)
        case .error:
            return .error
        }
    }

    private func severity(for health: ConnectionHealth) -> ConnectionDiagnosticSeverity {
        switch health {
        case .connected, .needsSetup, .testing:
            return .info
        case .degraded, .unknown:
            return .warning
        case .error:
            return .error
        }
    }

    private static func defaultStatusDetail(for health: ConnectionHealth) -> String {
        switch health {
        case .connected: "Connected"
        case .needsSetup: "Not configured"
        case .degraded: "Configured but not verified"
        case .error: "Needs attention"
        case .unknown: "Status unknown"
        case .testing: "Testing"
        }
    }

    private static func parseEventsLimit(_ req: Request) -> Int {
        guard let raw = req.uri.queryParameters["limit"].flatMap({ Int(String($0)) }) else {
            return defaultEventsLimit
        }
        return max(1, min(raw, maxEventsLimit))
    }

    private func providerKind(for id: ProviderID) -> ProviderKind {
        switch id {
        case .xai: .xai
        case .nvidia: .nvidia
        case .anthropic: .anthropic
        case .openai: .openai
        case .ollama: .ollama
        case .openRouter: .openRouter
        case .gemini: .gemini
        case .nous: .nous
        case .custom: .custom
        }
    }

    private func defaultCredentialKind(for id: ProviderID) -> ProviderCredentialKind {
        switch id {
        case .xai, .nvidia, .anthropic, .openai, .openRouter, .gemini, .nous: .apiKey
        case .ollama, .custom: .hostURL
        }
    }

    private func providerDisplayName(_ id: ProviderID) -> String {
        switch id {
        case .xai: "xAI"
        case .anthropic: "Anthropic"
        case .openai: "OpenAI"
        case .ollama: "Ollama"
        case .openRouter: "OpenRouter"
        case .nvidia: "NVIDIA NIM"
        case .gemini: "Google Gemini"
        case .nous: "Nous Research"
        case .custom: "Custom Endpoint"
        }
    }

    private func providerSubtitle(_ id: ProviderID, kind: ProviderCredentialKind, row: UserProviderCredential?) -> String {
        if let label = row?.label, !label.isEmpty {
            return label
        }
        if let baseURL = row?.baseURL, !baseURL.isEmpty {
            return baseURL
        }
        switch kind {
        case .apiKey: return "API key"
        case .oauth: return "OAuth account"
        case .hostURL:
            return id == .ollama ? "Local host URL" : "OpenAI-compatible URL"
        }
    }
}
