import Foundation

/// OTLP/JSON encoding of a logs export request, per
/// https://github.com/open-telemetry/opentelemetry-proto/blob/v1.3.2/opentelemetry/proto/collector/logs/v1/logs_service.proto
/// and the standard ResourceLogs/ScopeLogs/LogRecord hierarchy.
///
/// Only the fields needed to round-trip swift-otel `OTelLogRecord` are
/// modeled. Severity numbers follow the OTel spec
/// (https://opentelemetry.io/docs/specs/otel/logs/data-model/#field-severitynumber).
struct OTLPLogsRequest: Encodable {
    let resourceLogs: [OTLPResourceLogs]
}

struct OTLPResourceLogs: Encodable {
    let resource: OTLPResource
    let scopeLogs: [OTLPScopeLogs]
}

struct OTLPResource: Encodable {
    let attributes: [OTLPAttribute]
}

struct OTLPScopeLogs: Encodable {
    let scope: OTLPInstrumentationScope
    let logRecords: [OTLPLogRecord]
}

struct OTLPInstrumentationScope: Encodable {
    let name: String
    let version: String?
}

struct OTLPLogRecord: Encodable {
    /// Nanoseconds since Unix epoch, serialized as a JSON string per spec.
    let timeUnixNano: String
    let severityNumber: Int
    let severityText: String
    let body: OTLPAnyValue
    let attributes: [OTLPAttribute]
    /// Hex-encoded; empty string when the log record has no associated span.
    let traceId: String
    let spanId: String
}

struct OTLPAttribute: Encodable {
    let key: String
    let value: OTLPAnyValue
}

/// OTLP `AnyValue` proto, JSON-encoded as a one-of-keys object.
enum OTLPAnyValue: Encodable {
    case string(String)
    case bool(Bool)
    case int(Int64)
    case double(Double)

    enum CodingKeys: String, CodingKey {
        case stringValue, boolValue, intValue, doubleValue
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .string(s): try c.encode(s, forKey: .stringValue)
        case let .bool(b): try c.encode(b, forKey: .boolValue)
        // intValue is `sfixed64` in proto → MUST be a JSON string.
        case let .int(i): try c.encode(String(i), forKey: .intValue)
        case let .double(d): try c.encode(d, forKey: .doubleValue)
        }
    }
}

/// Maps swift-log severity → OTel `SeverityNumber`. Spec table:
/// https://opentelemetry.io/docs/specs/otel/logs/data-model/#field-severitynumber
enum OTLPSeverity {
    static func number(forLogLevel level: String) -> Int {
        switch level.lowercased() {
        case "trace": 1
        case "debug": 5
        case "info": 9
        case "notice": 10
        case "warning": 13
        case "error": 17
        case "critical": 21
        default: 0 // UNSPECIFIED
        }
    }
}
