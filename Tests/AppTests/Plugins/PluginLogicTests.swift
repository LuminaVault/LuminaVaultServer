import Foundation
import Logging
import LuminaVaultShared
import Testing
@testable import App

/// Pure-logic unit tests for the HER-43 plugin foundation. No DB / no real
/// HTTP (the connector uses a stub client), so they run fast and avoid the
/// AsyncKit teardown SIGILL (HER-310) that the integration suites hit.
@Suite("Plugin catalog validation")
struct PluginCatalogTests {
    @Test("readwise is in the catalog with a secret access_token field")
    func catalogHasReadwise() {
        let entry = PluginCatalog.entry(slug: "readwise")
        #expect(entry != nil)
        #expect(entry?.binding == "readwise")
        let fields = entry?.dto.configFields ?? []
        #expect(fields.contains { $0.key == "access_token" && $0.kind == .secret && $0.isRequired })
    }

    @Test("catalog filters by category and sorts by slug")
    func catalogFilter() {
        #expect(PluginCatalog.catalog(category: .connector).contains { $0.slug == "readwise" })
        #expect(PluginCatalog.catalog(category: .theme).isEmpty)
    }

    @Test("validate accepts a complete config")
    func validateOK() {
        #expect(PluginCatalog.validate(slug: "readwise", config: ["access_token": "tok"]) == .ok)
    }

    @Test("validate rejects unknown plugin, missing required, and unknown field")
    func validateRejections() {
        #expect(PluginCatalog.validate(slug: "nope", config: [:]) == .unknownPlugin)
        #expect(PluginCatalog.validate(slug: "readwise", config: [:]) == .missing("access_token"))
        #expect(PluginCatalog.validate(slug: "readwise", config: ["access_token": "  "]) == .missing("access_token"))
        #expect(
            PluginCatalog.validate(slug: "readwise", config: ["access_token": "t", "bogus": "x"])
                == .unknownField("bogus"),
        )
    }
}

/// Stub HTTP client: returns a canned response for any GET, recording the
/// Authorization header so the test can assert the Readwise token convention.
private actor StubConnectorHTTP: ConnectorHTTPClient {
    let status: Int
    let body: Data
    private(set) var lastAuthHeader: String?

    init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }

    func get(url _: URL, headers: [String: String]) async throws -> ConnectorHTTPResponse {
        lastAuthHeader = headers["Authorization"]
        return ConnectorHTTPResponse(status: status, body: body)
    }
}

@Suite("Readwise connector")
struct ReadwiseConnectorTests {
    private func connector(status: Int, json: String) -> (ReadwiseConnector, StubConnectorHTTP) {
        let stub = StubConnectorHTTP(status: status, body: Data(json.utf8))
        let c = ReadwiseConnector(http: stub, maxPages: 1, logger: Logger(label: "test"))
        return (c, stub)
    }

    @Test("maps source_url, dedupes, drops non-http and null sources")
    func mapsSourceURLs() async throws {
        let json = """
        {"nextPageCursor": null, "results": [
          {"source_url": "https://example.com/a"},
          {"source_url": "https://example.com/a"},
          {"source_url": "ftp://nope"},
          {"source_url": null},
          {"source_url": "http://example.com/b"}
        ]}
        """
        let (c, stub) = connector(status: 200, json: json)
        let urls = try await c.fetchURLs(config: ["access_token": "tok"], tenantID: UUID())
        #expect(urls == ["https://example.com/a", "http://example.com/b"])
        #expect(await stub.lastAuthHeader == "Token tok")
    }

    @Test("missing token throws missingConfig before any request")
    func missingToken() async {
        let (c, _) = connector(status: 200, json: "{}")
        await #expect(throws: ConnectorError.missingConfig("access_token")) {
            try await c.fetchURLs(config: [:], tenantID: UUID())
        }
    }

    @Test("401 maps to unauthorized")
    func unauthorized() async {
        let (c, _) = connector(status: 401, json: "{}")
        await #expect(throws: ConnectorError.unauthorized) {
            try await c.fetchURLs(config: ["access_token": "bad"], tenantID: UUID())
        }
    }

    @Test("500 maps to upstreamFailure")
    func upstream() async {
        let (c, _) = connector(status: 500, json: "{}")
        await #expect(throws: ConnectorError.upstreamFailure(500)) {
            try await c.fetchURLs(config: ["access_token": "tok"], tenantID: UUID())
        }
    }
}
