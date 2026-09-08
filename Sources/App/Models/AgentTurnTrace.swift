import FluentKit
import Foundation

/// The tool names for one turn, wrapped in a **keyed** type.
///
/// Deliberately not a bare `[String]` over the `jsonb` column. PostgresNIO
/// hands a `jsonb` value to the decoder as the column's raw JSON *text*, so
/// single-value-container types read back wrong — that is how
/// `HermesRunEventRow.payload` and `hermes_mirrored_jobs.raw` were both
/// corrupted on 2026-09-04, silently, because the write succeeds and the type
/// checks out. A keyed container decodes correctly, and
/// `AgentTurnTraceRoundTripTests` asserts the shape that comes back rather
/// than merely that a value came back.
struct AgentToolCalls: Codable, Equatable, Sendable {
    /// Tool names in call order. Can be empty while `count` is not: the
    /// streaming chat path observes tool *invocations* (`ChatStreamChunk
    /// .toolCallID`) without ever seeing their names, so "3 tools, names
    /// unknown" is a real and common state that must stay expressible.
    var names: [String]
    /// How many tools ran. Authoritative — `names` is best-effort detail.
    var count: Int

    init(names: [String]) {
        self.names = names
        count = names.count
    }

    /// For callers that can count invocations but cannot name them.
    init(count: Int, names: [String] = []) {
        self.names = names
        self.count = Swift.max(count, names.count)
    }

    private enum CodingKeys: String, CodingKey { case names, count }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        names = try container.decodeIfPresent([String].self, forKey: .names) ?? []
        // Rows written before `count` existed carry only names.
        count = try container.decodeIfPresent(Int.self, forKey: .count) ?? names.count
    }
}

/// One routed LLM call, and what it actually did (M123).
///
/// Records the two things the system computed and then threw away: which
/// model answered, and which tools it called. See the migration for why each
/// column exists.
final class AgentTurnTrace: Model, TenantModel, @unchecked Sendable {
    static let schema = "agent_turn_traces"

    @ID(key: .id) var id: UUID?
    @Field(key: "tenant_id") var tenantID: UUID
    /// Nil for routed calls that are not conversation turns — skill runs,
    /// workflow nodes, one-shot classifiers.
    @OptionalField(key: "conversation_message_id") var conversationMessageID: UUID?
    @Field(key: "provider") var provider: String
    @Field(key: "model") var model: String
    /// Tool names in call order. Empty = ran without tools (a real answer);
    /// nil = the response could not be read.
    @OptionalField(key: "tool_calls") var toolCalls: AgentToolCalls?
    @Field(key: "failover_count") var failoverCount: Int
    @Field(key: "tokens_in") var tokensIn: Int64
    @Field(key: "tokens_out") var tokensOut: Int64
    @Field(key: "estimated_cost_usd_micros") var estimatedCostUsdMicros: Int64
    @Field(key: "latency_ms") var latencyMs: Int64
    /// `managed` or `byok` — decides whether the cost column is our money or
    /// the user's.
    @OptionalField(key: "credential_mode") var credentialMode: String?
    @Timestamp(key: "occurred_at", on: .create) var occurredAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        tenantID: UUID,
        conversationMessageID: UUID? = nil,
        provider: String,
        model: String,
        toolCalls: AgentToolCalls? = nil,
        failoverCount: Int = 0,
        tokensIn: Int64 = 0,
        tokensOut: Int64 = 0,
        estimatedCostUsdMicros: Int64 = 0,
        latencyMs: Int64 = 0,
        credentialMode: String? = nil
    ) {
        self.id = id
        self.tenantID = tenantID
        self.conversationMessageID = conversationMessageID
        self.provider = provider
        self.model = model
        self.toolCalls = toolCalls
        self.failoverCount = failoverCount
        self.tokensIn = tokensIn
        self.tokensOut = tokensOut
        self.estimatedCostUsdMicros = estimatedCostUsdMicros
        self.latencyMs = latencyMs
        self.credentialMode = credentialMode
    }
}
