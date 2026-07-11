import Foundation
import Logging
import LuminaVaultShared

enum WhatsAppPairingError: Error, Equatable {
    case sessionNotFound
}

/// Orchestrates WhatsApp QR pairing for a tenant.
///
/// Unlike `HermesGatewayApplyService` this state is **ephemeral** — a pairing
/// session lives only as long as the CLI subprocess. If the SSE stream drops or
/// the server restarts the user simply re-opens the sheet and pairs again, so
/// nothing is persisted to the DB. The actor holds, per session: the live
/// streaming handle, the last QR + status (replayed to late subscribers), and
/// the set of SSE continuations to fan events out to.
///
/// Concurrency: `actor` isolation serialises all mutation. The stdout pump runs
/// in an actor-owned `Task` (not `Task.detached`) so it inherits the executor
/// and is cancelled cleanly on teardown.
actor WhatsAppPairingService {
    private let containerManager: HermesContainerManager
    private let backend: any WhatsAppPairingBackend
    private let logger: Logger

    private struct Session {
        var task: Task<Void, Never>?
        var handle: (any StreamingExecHandle)?
        var lastQR: String?
        var lastStatus: HermesWhatsAppPairStatus = .starting
        var terminal: HermesWhatsAppPairEvent?
        var subscribers: [UUID: AsyncThrowingStream<HermesWhatsAppPairEvent, Error>.Continuation] = [:]
    }

    /// sessionID → live session.
    private var sessions: [UUID: Session] = [:]
    /// tenantID → its current sessionID (single active pairing per tenant).
    private var tenantSession: [UUID: UUID] = [:]

    init(
        containerManager: HermesContainerManager,
        backend: any WhatsAppPairingBackend,
        logger: Logger
    ) {
        self.containerManager = containerManager
        self.backend = backend
        self.logger = logger
    }

    // MARK: - Public API

    /// Begin a pairing session for `tenantID`. Spawns (or reuses) the tenant
    /// container, launches `hermes whatsapp`, and returns the session id the
    /// client subscribes to. Any prior session for this tenant is torn down so
    /// only one QR is live at a time.
    func startPairing(tenantID: UUID) async throws -> UUID {
        if let old = tenantSession[tenantID] {
            await teardown(sessionID: old)
        }
        let handle = try await containerManager.ensureRunning(tenantID: tenantID)
        let exec = try await backend.startSession(handle: handle)

        let sessionID = UUID()
        var session = Session()
        session.handle = exec
        sessions[sessionID] = session
        tenantSession[tenantID] = sessionID

        let task = Task { [weak self] in
            guard let self else { return }
            await pump(sessionID: sessionID, exec: exec)
        }
        sessions[sessionID]?.task = task
        logger.info("whatsapp pairing started", metadata: [
            "tenantID": "\(tenantID)", "sessionID": "\(sessionID)",
        ])
        return sessionID
    }

    /// Subscribe to a pairing session's event stream. Replays the latest status
    /// + QR so a (re)connecting client sees current state immediately, then
    /// streams live events until the session reaches a terminal state.
    func subscribe(sessionID: UUID) -> AsyncThrowingStream<HermesWhatsAppPairEvent, Error> {
        AsyncThrowingStream { continuation in
            Task { await self.attach(sessionID: sessionID, continuation: continuation) }
        }
    }

    /// Whether the tenant already has a persisted WhatsApp session (drives the
    /// gateway row's `verified` status). Never spawns a container.
    func isPaired(tenantID: UUID) async -> Bool {
        guard let handle = try? await containerManager.handle(tenantID: tenantID) else {
            return false
        }
        return await backend.isPaired(handle: handle)
    }

    /// Unlink WhatsApp: tear down any live pairing, delete the persisted
    /// session, and restart the container so Baileys drops the connection.
    @discardableResult
    func unlink(tenantID: UUID) async throws -> Bool {
        if let sid = tenantSession[tenantID] {
            await teardown(sessionID: sid)
        }
        guard let handle = try? await containerManager.handle(tenantID: tenantID) else {
            return true // no container → nothing to unlink
        }
        let ok = try await backend.unlink(handle: handle)
        // Restart so the running Hermes drops the in-memory WhatsApp session.
        try? await containerManager.applyGatewayConfig(tenantID: tenantID)
        return ok
    }

    // MARK: - Subscriber attach/detach

    private func attach(
        sessionID: UUID,
        continuation: AsyncThrowingStream<HermesWhatsAppPairEvent, Error>.Continuation
    ) {
        guard var session = sessions[sessionID] else {
            continuation.finish(throwing: WhatsAppPairingError.sessionNotFound)
            return
        }
        // Replay current state for an immediate render.
        continuation.yield(.status(session.lastStatus))
        if let qr = session.lastQR {
            continuation.yield(.qr(qr))
        }
        if let terminal = session.terminal {
            continuation.yield(terminal)
            continuation.finish()
            return
        }
        let subID = UUID()
        session.subscribers[subID] = continuation
        sessions[sessionID] = session
        continuation.onTermination = { _ in
            Task { await self.detach(sessionID: sessionID, subID: subID) }
        }
    }

    private func detach(sessionID: UUID, subID: UUID) {
        sessions[sessionID]?.subscribers[subID] = nil
    }

    // MARK: - Stdout pump

    private func pump(sessionID: UUID, exec: any StreamingExecHandle) async {
        var parser = WhatsAppPairParser()
        for await line in exec.lines {
            for event in parser.consume(line: line) {
                handle(sessionID: sessionID, event: event)
            }
            if sessions[sessionID]?.terminal != nil {
                break
            }
        }
        for event in parser.finish() {
            handle(sessionID: sessionID, event: event)
        }
        // Process exited. If nothing terminal was parsed, infer from exit code.
        if sessions[sessionID]?.terminal == nil {
            let code = try? await exec.wait()
            let event: HermesWhatsAppPairEvent = code == 0
                ? .linked
                : .error("WhatsApp pairing ended before linking. Please try again.")
            handle(sessionID: sessionID, event: event)
        }
    }

    private func handle(sessionID: UUID, event: HermesWhatsAppPairEvent) {
        guard var session = sessions[sessionID] else { return }
        switch event {
        case let .qr(art):
            session.lastQR = art
            if session.lastStatus == .starting {
                session.lastStatus = .awaitingScan
            }
        case let .status(status):
            session.lastStatus = status
        case .linked:
            session.terminal = .linked
            session.lastStatus = .linked
        case .error:
            session.terminal = event
            session.lastStatus = .failed
        }
        sessions[sessionID] = session

        for cont in session.subscribers.values {
            cont.yield(event)
        }

        if session.terminal != nil {
            for cont in session.subscribers.values {
                cont.finish()
            }
            // Keep the session briefly so a late subscriber still sees the
            // terminal event, then reap.
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                await self?.teardown(sessionID: sessionID)
            }
        }
    }

    private func teardown(sessionID: UUID) async {
        guard let session = sessions.removeValue(forKey: sessionID) else { return }
        session.task?.cancel()
        for cont in session.subscribers.values {
            cont.finish()
        }
        await session.handle?.cancel()
        for (tenant, sid) in tenantSession where sid == sessionID {
            tenantSession[tenant] = nil
        }
    }
}
