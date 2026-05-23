import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
import Logging
import LuminaVaultShared

/// HER-241 — outbound client to the user's Hermes API server.
///
/// Per the Hermes API Server docs
/// (https://hermes-agent.nousresearch.com/docs/user-guide/features/api-server),
/// Hermes today exposes:
///
///   - `GET /v1/health` — reachability probe
///   - `POST /v1/chat/completions` (OpenAI-compatible, SSE on `stream:true`)
///   - `GET  /v1/runs/{run_id}/events` (SSE)
///   - `/api/jobs/...`
///
/// Auth scheme: `Authorization: Bearer $API_SERVER_KEY`.
///
/// Critically, there are **no documented endpoints for gateway
/// administration** (the `hermes gateway {setup,status,...}` commands
/// are CLI-only). Until upstream ships an admin HTTP API,
/// LuminaVaultServer stores the user-supplied gateway config encrypted
/// at rest and the user runs the CLI on their Hermes host to apply.
///
/// This client therefore exposes a single reachability check today.
/// The protocol surface is kept generous so that, once upstream lands
/// gateway endpoints, we add `setup(id:config:)` here without churning
/// any controller or DTO contracts downstream.
protocol HermesGatewayClienting: Sendable {
    /// Probe the user's Hermes server's `/v1/health` endpoint.
    /// Returns the classified reachability result; never throws.
    /// TODO(HER-241 follow-up): add `setup(id:config:)` when Hermes
    /// ships an admin HTTP API for gateway management. Today this is
    /// CLI-only — see plan `.planning/HER-241` for the swap-in point.
    func health(
        baseURL: URL,
        authHeader: String?,
    ) async -> HermesGatewayReachability
}

enum HermesGatewayReachability: Equatable {
    case reachable
    case unauthorized
    case unreachable(reason: String)

    /// Stable error code surfaced on `/test` responses. iOS keys off
    /// these to render localized error copy.
    var errorCode: String? {
        switch self {
        case .reachable: nil
        case .unauthorized: "hermes_unauthorized"
        case let .unreachable(reason): "hermes_unreachable:\(reason)"
        }
    }
}

struct HermesGatewayClient: HermesGatewayClienting {
    let session: URLSession
    let logger: Logger
    let probeTimeout: TimeInterval

    init(
        session: URLSession = .shared,
        logger: Logger,
        probeTimeout: TimeInterval = 5,
    ) {
        self.session = session
        self.logger = logger
        self.probeTimeout = probeTimeout
    }

    func health(baseURL: URL, authHeader: String?) async -> HermesGatewayReachability {
        let url = baseURL.appendingPathComponent("v1").appendingPathComponent("health")
        var req = URLRequest(url: url, timeoutInterval: probeTimeout)
        req.httpMethod = "GET"
        if let authHeader, !authHeader.isEmpty {
            req.setValue(authHeader, forHTTPHeaderField: "Authorization")
        }

        do {
            let (_, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                return .unreachable(reason: "no_http_response")
            }
            switch http.statusCode {
            case 200 ..< 300: return .reachable
            case 401, 403: return .unauthorized
            case 404: return .unreachable(reason: "not_found")
            case 500 ..< 600: return .unreachable(reason: "http_5xx")
            default: return .unreachable(reason: "http_\(http.statusCode)")
            }
        } catch let error as URLError {
            logger.debug("hermes /v1/health probe failed: \(error.code.rawValue) \(error.localizedDescription)")
            return .unreachable(reason: classify(error))
        } catch {
            logger.debug("hermes /v1/health probe failed: \(error)")
            return .unreachable(reason: "network")
        }
    }

    private func classify(_ error: URLError) -> String {
        switch error.code {
        case .timedOut: "timeout"
        case .cannotFindHost, .dnsLookupFailed: "dns"
        case .cannotConnectToHost: "connection_refused"
        case .secureConnectionFailed, .serverCertificateUntrusted: "tls"
        case .notConnectedToInternet: "no_internet"
        default: "network"
        }
    }
}
