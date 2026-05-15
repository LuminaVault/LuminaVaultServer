import Foundation
import HTTPTypes
import Hummingbird
import Logging

/// HER-164 — `GET /admin/llm/health` aggregator. Hits every registered
/// `OpenAICompatibleAdapter` (plus Hermes / Gemini once those adapters
/// adopt `healthCheck` in a follow-up) concurrently and returns one row
/// per provider with kind + region + ok + latencyMs. Behind
/// `AdminTokenMiddleware` (route-group level) — empty admin token at
/// boot disables the entire admin surface, fail-closed.
///
/// Wire shape kept inline (not in `LuminaVaultShared`) because consumers
/// are ops dashboards / curl, not iOS clients.
struct LLMHealthController {
    let registry: ProviderRegistry
    let logger: Logger

    func addRoutes(to router: RouterGroup<AppRequestContext>) {
        router.get("/llm/health", use: handle)
    }

    @Sendable
    func handle(_: Request, ctx _: AppRequestContext) async throws -> LLMHealthResponse {
        let registered = await registry.registered()
        // Snapshot OpenAI-compatible adapters first (only ones with a
        // landed healthCheck()). Hermes / Gemini follow when their
        // adapters grow healthCheck() in a separate ticket.
        var compatible: [(ProviderKind, OpenAICompatibleAdapter)] = []
        for kind in registered {
            if let adapter = await registry.adapter(for: kind) as? OpenAICompatibleAdapter {
                compatible.append((kind, adapter))
            }
        }

        let lines: [LLMProviderHealthLine] = await withTaskGroup(of: LLMProviderHealthLine.self) { group in
            for (kind, adapter) in compatible {
                group.addTask {
                    let result = await adapter.healthCheck()
                    return LLMProviderHealthLine(
                        kind: kind.rawValue,
                        region: kind.region.rawValue,
                        ok: result.ok,
                        latencyMs: result.latencyMs,
                        error: result.error,
                    )
                }
            }
            var out: [LLMProviderHealthLine] = []
            for await line in group {
                out.append(line)
            }
            return out.sorted(by: { $0.kind < $1.kind })
        }

        return LLMHealthResponse(checkedAt: Date(), providers: lines)
    }
}

// MARK: - Wire DTOs (server-only)

struct LLMProviderHealthLine: Codable, Sendable {
    let kind: String
    let region: String
    let ok: Bool
    let latencyMs: Int
    let error: String?

    enum CodingKeys: String, CodingKey {
        case kind, region, ok
        case latencyMs = "latency_ms"
        case error
    }
}

struct LLMHealthResponse: Codable, Sendable, ResponseEncodable {
    let checkedAt: Date
    let providers: [LLMProviderHealthLine]

    enum CodingKeys: String, CodingKey {
        case checkedAt = "checked_at"
        case providers
    }
}
