import FluentKit
import Foundation
import HummingbirdFluent
import Logging
import LuminaVaultShared
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

enum PhotonProvisioningError: Error, Equatable {
    case sessionNotFound
    case invalidPhone(String)
    case alreadyCompleted
    case timeout
}

/// Orchestrates the Photon iMessage provisioning flow for a tenant (the "free path").
///
/// Flow (driven from iOS + SSE):
/// 1. `startSetup(tenantID)` → returns sessionID. Immediately emits `.deviceCode(...)` + status `.awaitingApproval`.
///    Launches a background poller that hits Photon's device-code token endpoint.
/// 2. Client shows verification URI / user code (or opens browser). User approves on photon.codes.
/// 3. Client collects E.164 phone and calls `submitPhone(sessionID, phone)`.
/// 4. Once approval + phone are both present, the service performs the remaining steps over
///    the Photon dashboard + Spectrum APIs:
///      - create/find "Lumina Agent" project (with spectrum: true)
///      - ensure Spectrum enabled → spectrumProjectId
///      - regenerate project secret
///      - register Spectrum user for the phone (idempotent)
///      - obtain the assigned iMessage line (the number contacts text)
/// 5. On success: seal the runtime creds (spectrumProjectId + secret + dashboard id + bound phone + line)
///    into a `UserHermesGateway` row (gatewayID = "photon"), emit `.done` + `.assignedLine`.
/// 6. Client can then "apply" (which will later activate the central sidecar with the creds).
///
/// Sessions are ephemeral (like WhatsApp pairing). If the SSE drops or server restarts, the
/// user simply re-opens the setup sheet. The final creds live in the encrypted gateway row.
///
/// Concurrency: actor-isolated. Polling and provisioning run in actor-owned Tasks.
actor PhotonProvisioningService {
    private let fluent: Fluent
    private let secretBox: SecretBox
    private let logger: Logger
    private let sidecarClient: (any PhotonSidecarClienting)?

    private struct Session {
        var deviceCode: DeviceCode?
        var dashboardToken: String?
        var phone: String?
        var status: HermesPhotonSetupStatus = .starting
        var lastAssignedLine: String?
        var subscribers: [UUID: AsyncThrowingStream<HermesPhotonSetupEvent, Error>.Continuation] = [:]
        var poller: Task<Void, Never>?
        var provisioningTask: Task<Void, Never>?
        var completed: Bool = false
    }

    private struct DeviceCode {
        let deviceCode: String
        let userCode: String
        let verificationUri: String
        let verificationUriComplete: String?
        let expiresIn: Int
        let interval: Int
    }

    /// sessionID → live session state
    private var sessions: [UUID: Session] = [:]
    /// tenantID → its current session (only one active setup per tenant)
    private var tenantSession: [UUID: UUID] = [:]

    // Photon constants (from Hermes reference implementation)
    private let dashboardHost = "https://app.photon.codes"
    private let spectrumHost = "https://spectrum.photon.codes"
    private let clientID = "photon-cli"
    private let defaultScope = "openid profile email"
    private let defaultProjectName = "Lumina Agent"

    init(fluent: Fluent, secretBox: SecretBox, logger: Logger, sidecarClient: (any PhotonSidecarClienting)? = nil) {
        self.fluent = fluent
        self.secretBox = secretBox
        self.logger = logger
        self.sidecarClient = sidecarClient
    }

    // MARK: - Public API

    /// Start a new provisioning session for the tenant. Returns the sessionID the
    /// client will use for phone submission and SSE subscription.
    /// Any previous session for the tenant is torn down.
    func startSetup(tenantID: UUID) async throws -> UUID {
        if let old = tenantSession[tenantID] {
            await teardown(sessionID: old)
        }

        let sessionID = UUID()
        var session = Session()
        sessions[sessionID] = session
        tenantSession[tenantID] = sessionID

        // Immediately request device code and emit to any early subscribers
        let code = try await requestDeviceCode()
        session.deviceCode = code
        session.status = .awaitingApproval
        sessions[sessionID] = session

        emit(sessionID: sessionID, event: .deviceCode(
            verificationUri: code.verificationUriComplete ?? code.verificationUri,
            userCode: code.userCode,
            expiresIn: code.expiresIn
        ))
        emit(sessionID: sessionID, event: .status(.awaitingApproval))

        // Launch poller that waits for user approval (device token)
        let poller = Task { [weak self] in
            guard let self else { return }
            await runDeviceTokenPoller(sessionID: sessionID, code: code)
        }
        sessions[sessionID]?.poller = poller

        logger.info("photon setup started", metadata: [
            "tenantID": .stringConvertible(tenantID),
            "sessionID": .stringConvertible(sessionID),
        ])
        return sessionID
    }

    /// Submit (or update) the E.164 phone number for Spectrum user binding.
    /// If the dashboard token has already arrived, this triggers the remaining
    /// provisioning (project / spectrum / user / line). Otherwise it just stores
    /// the phone and the poller will trigger provisioning on approval.
    func submitPhone(sessionID: UUID, phone: String) async throws {
        guard var session = sessions[sessionID], !session.completed else {
            throw PhotonProvisioningError.sessionNotFound
        }

        let normalized = normalizePhone(phone)
        guard Self.E164_RE.firstMatch(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)) != nil else {
            throw PhotonProvisioningError.invalidPhone(phone)
        }

        session.phone = normalized
        sessions[sessionID] = session

        logger.info("photon phone submitted", metadata: [
            "sessionID": .stringConvertible(sessionID),
            "phone": .stringConvertible(normalized),
        ])

        // If we already have a token, kick off provisioning now.
        if session.dashboardToken != nil {
            await startProvisioningIfReady(sessionID: sessionID)
        }
    }

    /// Subscribe to live progress for a session. Replays recent state, then streams
    /// until terminal (done or error).
    func subscribe(sessionID: UUID) -> AsyncThrowingStream<HermesPhotonSetupEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                await self.attachSubscriber(sessionID: sessionID, continuation: continuation)
            }
        }
    }

    /// Called by controller on success path or by client to clean up.
    func teardown(sessionID: UUID) async {
        guard var session = sessions[sessionID] else { return }
        session.poller?.cancel()
        session.provisioningTask?.cancel()
        for cont in session.subscribers.values {
            cont.finish()
        }
        session.subscribers.removeAll()
        sessions[sessionID] = session

        // Remove tenant mapping if this was the active one
        if let tenant = tenantSession.first(where: { $0.value == sessionID })?.key {
            tenantSession.removeValue(forKey: tenant)
        }
        sessions.removeValue(forKey: sessionID)
    }

    // MARK: - Internal

    private func attachSubscriber(sessionID: UUID, continuation: AsyncThrowingStream<HermesPhotonSetupEvent, Error>.Continuation) async {
        guard var session = sessions[sessionID] else {
            continuation.finish(throwing: PhotonProvisioningError.sessionNotFound)
            return
        }

        let subID = UUID()
        session.subscribers[subID] = continuation

        // Replay current state
        if let code = session.deviceCode, session.status == .awaitingApproval || session.status == .starting {
            continuation.yield(.deviceCode(
                verificationUri: code.verificationUriComplete ?? code.verificationUri,
                userCode: code.userCode,
                expiresIn: code.expiresIn
            ))
        }
        continuation.yield(.status(session.status))
        if let line = session.lastAssignedLine {
            continuation.yield(.assignedLine(line))
        }

        sessions[sessionID] = session

        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(sessionID: sessionID, subID: subID) }
        }
    }

    private func removeSubscriber(sessionID: UUID, subID: UUID) async {
        sessions[sessionID]?.subscribers.removeValue(forKey: subID)
    }

    private func emit(sessionID: UUID, event: HermesPhotonSetupEvent) {
        guard var session = sessions[sessionID] else { return }
        for cont in session.subscribers.values {
            cont.yield(event)
        }
        // Update local status from events where useful
        if case let .status(s) = event {
            session.status = s
        }
        if case let .assignedLine(line) = event {
            session.lastAssignedLine = line
        }
        if case .status(.done) = event {
            session.completed = true
        }
        if case .error = event {
            session.completed = true
            session.status = .failed
        }
        sessions[sessionID] = session
    }

    private func runDeviceTokenPoller(sessionID: UUID, code: DeviceCode) async {
        let deadline = Date().addingTimeInterval(TimeInterval(code.expiresIn))
        var sleepSeconds = TimeInterval(code.interval)

        while Date() < deadline {
            if sessions[sessionID]?.completed == true { return }

            try? await Task.sleep(nanoseconds: UInt64(sleepSeconds * 1_000_000_000))

            do {
                if let token = try await pollForDeviceToken(code: code) {
                    // Validate like Hermes does
                    let validToken = try await validateDashboardToken(token)

                    guard var session = sessions[sessionID], !session.completed else { return }
                    session.dashboardToken = validToken
                    session.status = .approved
                    sessions[sessionID] = session

                    emit(sessionID: sessionID, event: .status(.approved))

                    // If phone already provided, proceed immediately
                    if session.phone != nil {
                        await startProvisioningIfReady(sessionID: sessionID)
                    }
                    return
                }
            } catch {
                // transient errors during polling are ok; keep trying until timeout
                logger.debug("photon device poll transient error", metadata: ["error": "\(error)"])
            }

            // exponential-ish backoff with cap (mirrors Hermes slow_down handling)
            sleepSeconds = min(sleepSeconds * 1.5, 15)
        }

        // timeout
        emit(sessionID: sessionID, event: .error("Photon device approval timed out"))
        await teardown(sessionID: sessionID)
    }

    private func startProvisioningIfReady(sessionID: UUID) async {
        guard var session = sessions[sessionID],
              let token = session.dashboardToken,
              let phone = session.phone,
              !session.completed,
              session.provisioningTask == nil else { return }

        let task = Task { [weak self] in
            guard let self else { return }
            await performProvisioning(sessionID: sessionID, dashboardToken: token, phone: phone)
        }
        session.provisioningTask = task
        sessions[sessionID] = session
    }

    private func performProvisioning(sessionID: UUID, dashboardToken: String, phone: String) async {
        do {
            emit(sessionID: sessionID, event: .status(.provisioning))

            // 1. Find or create project (dashboard token)
            var dashboardProjectID = try await findOrCreateProject(token: dashboardToken, name: defaultProjectName)

            // 2. Ensure Spectrum enabled → get spectrumProjectId
            let proj = try await ensureSpectrumEnabled(token: dashboardToken, projectID: dashboardProjectID)
            guard let spectrumID = proj["spectrumProjectId"] as? String ?? proj["spectrumProjectId"] as? String else {
                throw NSError(domain: "photon", code: 1, userInfo: [NSLocalizedDescriptionKey: "no spectrumProjectId"])
            }

            // 3. Regenerate secret (only time we can read it)
            let secret = try await regenerateProjectSecret(token: dashboardToken, projectID: dashboardProjectID)

            // 4. Register Spectrum user (uses spectrum basic auth)
            let (user, _) = try await registerUserIfAbsent(
                projectID: spectrumID,
                projectSecret: secret,
                phone: phone
            )

            let assignedLine = userAssignedLine(user: user)

            // 5. Persist sealed gateway row
            try await persistGatewayRow(
                sessionID: sessionID,
                spectrumProjectID: spectrumID,
                projectSecret: secret,
                dashboardProjectID: dashboardProjectID,
                boundPhone: phone,
                assignedLine: assignedLine
            )

            if let line = assignedLine {
                emit(sessionID: sessionID, event: .assignedLine(line))
            }
            emit(sessionID: sessionID, event: .status(.done))
            emit(sessionID: sessionID, event: .status(.done)) // duplicate harmless for clients

            logger.info("photon provisioning complete", metadata: [
                "sessionID": .stringConvertible(sessionID),
                "spectrumProjectId": .stringConvertible(spectrumID),
                "assignedLine": .stringConvertible(assignedLine ?? "none"),
            ])

            // Mark completed; keep session briefly for final subscribers then teardown
            if var s = sessions[sessionID] {
                s.completed = true
                sessions[sessionID] = s
            }

            // Give subscribers a moment, then clean
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await teardown(sessionID: sessionID)

        } catch {
            logger.error("photon provisioning failed", metadata: [
                "sessionID": .stringConvertible(sessionID),
                "error": .stringConvertible(String(describing: error)),
            ])
            emit(sessionID: sessionID, event: .error("Provisioning failed: \(error)"))
            await teardown(sessionID: sessionID)
        }
    }

    // MARK: - HTTP helpers (modeled on Hermes auth.py)

    private func requestDeviceCode() async throws -> DeviceCode {
        let url = URL(string: "\(dashboardHost)/api/auth/device/code")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["client_id": clientID, "scope": defaultScope]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        try checkStatus(resp, data: data, action: "device/code")

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        return DeviceCode(
            deviceCode: json["device_code"] as? String ?? "",
            userCode: json["user_code"] as? String ?? "",
            verificationUri: json["verification_uri"] as? String ?? "",
            verificationUriComplete: json["verification_uri_complete"] as? String,
            expiresIn: json["expires_in"] as? Int ?? 1800,
            interval: json["interval"] as? Int ?? 5
        )
    }

    private func pollForDeviceToken(code: DeviceCode) async throws -> String? {
        let url = URL(string: "\(dashboardHost)/api/auth/device/token")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            "device_code": code.deviceCode,
            "client_id": clientID,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0

        if status == 200 {
            let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            // Collect candidates like Hermes (access_token, data.*, header, etc.)
            if let token = extractTokenCandidate(from: json, headers: (resp as? HTTPURLResponse)?.allHeaderFields) {
                return token
            }
            return nil
        }

        if status == 400 {
            let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            let err = (json["error"] as? String) ?? ""
            if err == "authorization_pending" || err == "slow_down" {
                return nil
            }
            if err == "expired_token" || err == "access_denied" {
                throw NSError(domain: "photon", code: 400, userInfo: [NSLocalizedDescriptionKey: err])
            }
        }
        return nil
    }

    private func validateDashboardToken(_ token: String) async throws -> String {
        // Minimal validation: call get-session
        let url = URL(string: "\(dashboardHost)/api/auth/get-session")!
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (_, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode == 200 {
            return token
        }
        throw NSError(domain: "photon", code: 401, userInfo: [NSLocalizedDescriptionKey: "dashboard token rejected by get-session"])
    }

    private func findOrCreateProject(token: String, name: String) async throws -> String {
        // list and find
        let projects = try await listProjects(token: token)
        if let existing = projects.first(where: { ($0["name"] as? String)?.lowercased() == name.lowercased() }),
           let id = existing["id"] as? String
        {
            return id
        }

        // create
        let url = URL(string: "\(dashboardHost)/api/projects")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = [
            "name": name,
            "location": "United States",
            "spectrum": true,
            "template": false,
            "observability": false,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        try checkStatus(resp, data: data, action: "create project")

        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        if let id = json["id"] as? String { return id }
        throw NSError(domain: "photon", code: 0, userInfo: [NSLocalizedDescriptionKey: "no project id returned"])
    }

    private func listProjects(token: String) async throws -> [[String: Any]] {
        let url = URL(string: "\(dashboardHost)/api/projects")!
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, resp) = try await URLSession.shared.data(for: req)
        try checkStatus(resp, data: data, action: "list projects")

        let json = try JSONSerialization.jsonObject(with: data)
        return unwrapList(json)
    }

    private func ensureSpectrumEnabled(token: String, projectID: String) async throws -> [String: Any] {
        var proj = try await getProject(token: token, projectID: projectID)
        if (proj["spectrum"] as? Bool) != true {
            let url = URL(string: "\(dashboardHost)/api/projects/\(projectID)/spectrum/toggle")!
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (_, resp) = try await URLSession.shared.data(for: req)
            try checkStatus(resp, data: Data(), action: "spectrum toggle")
            proj = try await getProject(token: token, projectID: projectID)
        }
        return proj
    }

    private func getProject(token: String, projectID: String) async throws -> [String: Any] {
        let url = URL(string: "\(dashboardHost)/api/projects/\(projectID)")!
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        try checkStatus(resp, data: data, action: "get project")
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private func regenerateProjectSecret(token: String, projectID: String) async throws -> String {
        let url = URL(string: "\(dashboardHost)/api/projects/\(projectID)/regenerate-secret")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        try checkStatus(resp, data: data, action: "regenerate secret")
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        if let secret = json["projectSecret"] as? String { return secret }
        throw NSError(domain: "photon", code: 0, userInfo: [NSLocalizedDescriptionKey: "no projectSecret"])
    }

    /// Spectrum user ops (Basic auth with project:secret)
    private func registerUserIfAbsent(projectID: String, projectSecret: String, phone: String) async throws -> ([String: Any], Bool) {
        if let existing = try await findUserByPhone(projectID: projectID, projectSecret: projectSecret, phone: phone) {
            return (existing, false)
        }
        let user = try await createUser(projectID: projectID, projectSecret: projectSecret, phone: phone)
        return (user, true)
    }

    private func findUserByPhone(projectID: String, projectSecret: String, phone: String) async throws -> [String: Any]? {
        let users = try await listSpectrumUsers(projectID: projectID, projectSecret: projectSecret)
        let target = normalizePhone(phone)
        for u in users {
            if normalizePhone(u["phoneNumber"] as? String ?? "") == target {
                return u
            }
        }
        return nil
    }

    private func listSpectrumUsers(projectID: String, projectSecret: String) async throws -> [[String: Any]] {
        let url = URL(string: "\(spectrumHost)/projects/\(projectID)/users/")!
        var req = URLRequest(url: url)
        let basic = Data("\(projectID):\(projectSecret)".utf8).base64EncodedString()
        req.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        try checkStatus(resp, data: data, action: "list spectrum users")
        let json = try JSONSerialization.jsonObject(with: data)
        return unwrapList(json)
    }

    private func createUser(projectID: String, projectSecret: String, phone: String) async throws -> [String: Any] {
        let url = URL(string: "\(spectrumHost)/projects/\(projectID)/users/")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let basic = Data("\(projectID):\(projectSecret)".utf8).base64EncodedString()
        req.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = ["type": "shared", "phoneNumber": phone]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        try checkStatus(resp, data: data, action: "create spectrum user")
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        if let user = json["user"] as? [String: Any] ?? json["data"] as? [String: Any] {
            return user
        }
        return json
    }

    private func userAssignedLine(user: [String: Any]?) -> String? {
        guard let u = user else { return nil }
        return u["assignedPhoneNumber"] as? String
    }

    // MARK: - Persistence (sealed gateway row)

    private func persistGatewayRow(
        sessionID: UUID,
        spectrumProjectID: String,
        projectSecret: String,
        dashboardProjectID: String,
        boundPhone: String,
        assignedLine: String?
    ) async throws {
        // We need tenantID. Walk backwards from session map (or pass it through).
        // For simplicity in this implementation we look it up.
        guard let tenantID = tenantSession.first(where: { $0.value == sessionID })?.key else {
            throw PhotonProvisioningError.sessionNotFound
        }

        let config: [String: String] = [
            "spectrum_project_id": spectrumProjectID,
            "project_secret": projectSecret,
            "dashboard_project_id": dashboardProjectID,
            "bound_phone": boundPhone,
            "assigned_line": assignedLine ?? "",
        ]

        let sealed = try secretBox.seal(encodeConfig(config), tenantID: tenantID)

        // Upsert the gateway row
        if let existing = try await UserHermesGateway.query(on: fluent.db())
            .filter(\.$tenantID == tenantID)
            .filter(\.$gatewayID == HermesGatewayID.photon.rawValue)
            .first()
        {
            existing.configCiphertext = sealed.ciphertext
            existing.configNonce = sealed.nonce
            existing.status = HermesGatewayStatus.configured.rawValue
            existing.verifiedAt = nil
            existing.lastFailureAt = nil
            existing.lastFailureCode = nil
            try await existing.update(on: fluent.db())
        } else {
            let row = UserHermesGateway()
            row.tenantID = tenantID
            row.gatewayID = HermesGatewayID.photon.rawValue
            row.configCiphertext = sealed.ciphertext
            row.configNonce = sealed.nonce
            row.status = HermesGatewayStatus.configured.rawValue
            try await row.create(on: fluent.db())
        }

        // Auto-activate the central sidecar with the freshly provisioned creds so inbound starts flowing.
        if let client = sidecarClient {
            do {
                try await client.activate(
                    projectId: spectrumProjectID,
                    projectSecret: projectSecret,
                    tenantId: tenantID,
                    options: nil
                )
                logger.info("photon sidecar auto-activated after provisioning", metadata: [
                    "tenantID": .stringConvertible(tenantID),
                ])
            } catch {
                logger.warning("photon sidecar activate after provisioning failed (will retry on apply)", metadata: [
                    "error": .stringConvertible(String(describing: error)),
                ])
            }
        }
    }

    private func encodeConfig(_ dict: [String: String]) throws -> String {
        let data = try JSONEncoder().encode(dict)
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Tiny HTTP utilities

    private func checkStatus(_ response: URLResponse, data: Data, action: String) throws {
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "photon", code: http.statusCode, userInfo: [
                NSLocalizedDescriptionKey: "Photon \(action) failed: HTTP \(http.statusCode): \(text.prefix(300))",
            ])
        }
    }

    private func unwrapList(_ json: Any) -> [[String: Any]] {
        if let arr = json as? [[String: Any]] { return arr }
        if let dict = json as? [String: Any] {
            for key in ["data", "projects", "users", "items"] {
                if let inner = dict[key] as? [[String: Any]] { return inner }
            }
        }
        return []
    }

    private func extractTokenCandidate(from body: [String: Any], headers: [AnyHashable: Any]?) -> String? {
        // Simplified version of Hermes _device_response_token_candidates
        if let t = body["access_token"] as? String { return cleanBearer(t) }
        if let t = body["accessToken"] as? String { return cleanBearer(t) }
        if let session = body["session"] as? [String: Any], let t = session["access_token"] as? String { return cleanBearer(t) }
        if let data = body["data"] as? [String: Any] {
            if let t = data["access_token"] as? String { return cleanBearer(t) }
            if let t = data["accessToken"] as? String { return cleanBearer(t) }
        }
        if let h = headers, let t = h["set-auth-token"] as? String ?? h["Set-Auth-Token"] as? String {
            return cleanBearer(t)
        }
        return nil
    }

    private func cleanBearer(_ v: String) -> String {
        let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.lowercased().hasPrefix("bearer ") { return String(t.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
        return t
    }

    private func normalizePhone(_ p: String) -> String {
        p.replacingOccurrences(of: "[^\\d+]", with: "", options: .regularExpression)
    }

    // swiftlint:disable:next force_try
    private static let E164_RE = try! NSRegularExpression(pattern: "^\\+[1-9]\\d{6,14}$")
}
