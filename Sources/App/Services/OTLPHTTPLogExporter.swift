import AsyncHTTPClient
import Foundation
import Logging
import NIOCore
import NIOFoundationCompat
@_spi(Logging) import OTel
import Tracing

/// HER-236: ships swift-otel `OTelLogRecord` batches to an OTLP/HTTP receiver
/// (the in-stack `otel-collector` service) as JSON.
///
/// swift-otel 0.12.0 ships the log handler + batch processor + protocol but no
/// OTLP HTTP exporter — this fills that gap. Spec:
/// https://github.com/open-telemetry/opentelemetry-proto/blob/v1.3.2/opentelemetry/proto/collector/logs/v1/logs_service.proto
struct OTLPHTTPLogExporter: OTelLogRecordExporter {
    private let httpClient: HTTPClient
    private let endpoint: String
    private let headers: [(String, String)]
    private let encoder: JSONEncoder
    private let ownsClient: Bool

    init(
        endpoint: String,
        headers: [(String, String)] = [],
        httpClient: HTTPClient? = nil
    ) {
        self.endpoint = endpoint
        self.headers = headers
        if let httpClient {
            self.httpClient = httpClient
            ownsClient = false
        } else {
            self.httpClient = HTTPClient(eventLoopGroupProvider: .singleton)
            ownsClient = true
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        self.encoder = encoder
    }

    func export(_ batch: some Collection<OTelLogRecord> & Sendable) async throws {
        guard !batch.isEmpty else { return }
        let payload = Self.encode(batch: batch)
        let body = try encoder.encode(payload)

        var request = HTTPClientRequest(url: endpoint)
        request.method = .POST
        request.headers.add(name: "content-type", value: "application/json")
        for (k, v) in headers {
            request.headers.add(name: k, value: v)
        }
        request.body = .bytes(ByteBuffer(data: body))

        let response = try await httpClient.execute(request, timeout: .seconds(10))
        guard (200 ..< 300).contains(response.status.code) else {
            let detail = try? await response.body.collect(upTo: 2 * 1024)
            throw OTLPHTTPLogExporterError.unexpectedStatus(
                code: response.status.code,
                body: detail.map { String(buffer: $0) } ?? ""
            )
        }
    }

    func forceFlush() async throws {
        // BatchLogRecordProcessor drives flushing; nothing to do here.
    }

    func shutdown() async {
        guard ownsClient else { return }
        try? await httpClient.shutdown()
    }

    // MARK: - Encoding

    static func encode(batch: some Collection<OTelLogRecord>) -> OTLPLogsRequest {
        var groups: [ResourceKey: [OTelLogRecord]] = [:]
        var order: [ResourceKey] = []
        for record in batch {
            let key = ResourceKey(record.resource)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(record)
        }

        let resourceLogs = order.map { key -> OTLPResourceLogs in
            let records = groups[key] ?? []
            return OTLPResourceLogs(
                resource: OTLPResource(attributes: key.resource.attributes.asOTLPAttributes()),
                scopeLogs: [
                    OTLPScopeLogs(
                        scope: OTLPInstrumentationScope(name: "luminavault.app", version: nil),
                        logRecords: records.map(makeLogRecord)
                    ),
                ]
            )
        }
        return OTLPLogsRequest(resourceLogs: resourceLogs)
    }

    private static func makeLogRecord(_ r: OTelLogRecord) -> OTLPLogRecord {
        let attrs = r.metadata.map { key, value in
            OTLPAttribute(key: key, value: .string(metadataString(value)))
        }
        return OTLPLogRecord(
            timeUnixNano: String(r.timeNanosecondsSinceEpoch),
            severityNumber: OTLPSeverity.number(forLogLevel: r.level.rawValue),
            severityText: r.level.rawValue.uppercased(),
            body: .string(r.body.description),
            attributes: attrs,
            traceId: r.spanContext.map { String(describing: $0.traceID) } ?? "",
            spanId: r.spanContext.map { String(describing: $0.spanID) } ?? ""
        )
    }

    private static func metadataString(_ v: Logger.MetadataValue) -> String {
        switch v {
        case let .string(s): s
        case let .stringConvertible(c): c.description
        case let .array(arr): "[" + arr.map(metadataString).joined(separator: ",") + "]"
        case let .dictionary(dict):
            "{" + dict.map { "\($0.key)=\(metadataString($0.value))" }.sorted().joined(separator: ",") + "}"
        }
    }

    /// Identity wrapper so we can group records by `OTelResource` (Equatable
    /// but not Hashable upstream).
    private struct ResourceKey: Hashable {
        let resource: OTelResource
        init(_ r: OTelResource) {
            resource = r
        }

        func hash(into hasher: inout Hasher) {
            var keys: [String] = []
            resource.attributes.forEach { k, _ in keys.append(k) }
            hasher.combine(keys.sorted())
        }
    }
}

enum OTLPHTTPLogExporterError: Error, CustomStringConvertible {
    case unexpectedStatus(code: UInt, body: String)

    var description: String {
        switch self {
        case let .unexpectedStatus(code, body):
            "OTLP log export failed: HTTP \(code) \(body)"
        }
    }
}

private extension SpanAttributes {
    func asOTLPAttributes() -> [OTLPAttribute] {
        var out: [OTLPAttribute] = []
        forEach { key, value in
            switch value {
            case let .string(s): out.append(OTLPAttribute(key: key, value: .string(s)))
            case let .int32(i): out.append(OTLPAttribute(key: key, value: .int(Int64(i))))
            case let .int64(i): out.append(OTLPAttribute(key: key, value: .int(i)))
            case let .double(d): out.append(OTLPAttribute(key: key, value: .double(d)))
            case let .bool(b): out.append(OTLPAttribute(key: key, value: .bool(b)))
            case let .stringConvertible(c): out.append(OTLPAttribute(key: key, value: .string(c.description)))
            case let .stringArray(arr): out.append(OTLPAttribute(key: key, value: .string(arr.joined(separator: ","))))
            default: out.append(OTLPAttribute(key: key, value: .string(String(describing: value))))
            }
        }
        return out
    }
}
