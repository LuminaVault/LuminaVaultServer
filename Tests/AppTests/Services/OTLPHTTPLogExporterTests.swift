@testable import App
import Foundation
import Testing

/// HER-236 — JSON-shape contract test for the OTLP/JSON encoding layer.
/// Goes through the public `OTLPLogsRequest` model graph (the boundary with
/// the otel-collector), not through swift-otel's package-protected
/// `OTelLogRecord` initializer. The encoder is what the collector parses;
/// the bridge from `OTelLogRecord` is exercised end-to-end in dev compose.
struct OTLPHTTPLogExporterTests {
    @Test
    func `severity number mapping covers swift-log levels`() {
        #expect(OTLPSeverity.number(forLogLevel: "trace") == 1)
        #expect(OTLPSeverity.number(forLogLevel: "debug") == 5)
        #expect(OTLPSeverity.number(forLogLevel: "info") == 9)
        #expect(OTLPSeverity.number(forLogLevel: "notice") == 10)
        #expect(OTLPSeverity.number(forLogLevel: "warning") == 13)
        #expect(OTLPSeverity.number(forLogLevel: "error") == 17)
        #expect(OTLPSeverity.number(forLogLevel: "critical") == 21)
        #expect(OTLPSeverity.number(forLogLevel: "bogus") == 0)
    }

    @Test
    func `encodes OTLP logs request matching collector schema`() throws {
        let payload = OTLPLogsRequest(resourceLogs: [
            OTLPResourceLogs(
                resource: OTLPResource(attributes: [
                    OTLPAttribute(key: "service.name", value: .string("luminavault")),
                ]),
                scopeLogs: [
                    OTLPScopeLogs(
                        scope: OTLPInstrumentationScope(name: "luminavault.app", version: nil),
                        logRecords: [
                            OTLPLogRecord(
                                timeUnixNano: "1700000000000000000",
                                severityNumber: 9,
                                severityText: "INFO",
                                body: .string("hello world"),
                                attributes: [OTLPAttribute(key: "request_id", value: .string("abc-123"))],
                                traceId: "",
                                spanId: ""
                            ),
                        ]
                    ),
                ]
            ),
        ])

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(payload)
        let json = String(decoding: data, as: UTF8.self)

        #expect(json.contains(#""key":"service.name""#))
        #expect(json.contains(#""stringValue":"luminavault""#))
        #expect(json.contains(#""body":{"stringValue":"hello world"}"#))
        #expect(json.contains(#""severityNumber":9"#))
        #expect(json.contains(#""severityText":"INFO""#))
        #expect(json.contains(#""timeUnixNano":"1700000000000000000""#))
        #expect(json.contains(#""key":"request_id""#))
        #expect(json.contains(#""stringValue":"abc-123""#))
    }

    @Test
    func `int AnyValue is encoded as JSON string per OTLP spec`() throws {
        // intValue is sfixed64 in proto → JSON requires string encoding.
        let attr = OTLPAttribute(key: "http.status_code", value: .int(404))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(attr)
        #expect(String(decoding: data, as: UTF8.self) == #"{"key":"http.status_code","value":{"intValue":"404"}}"#)
    }
}
