@testable import App
import Foundation
import Testing

/// Contract tests for the MCP surface.
///
/// The tool set, its schemas, and its bounds are what an agent builds against.
/// Changing one silently breaks every client, so these assertions exist to make
/// a change deliberate rather than accidental — the same reason NexusOS froze
/// its contract behind a test suite before v0.1.
struct MCPContractTests {
    private static let expectedTools = [
        "status", "search", "browse", "read", "recent", "links", "context", "index",
    ]

    @Test
    func `the advertised tool set is exactly these eight`() {
        #expect(MCPToolCatalog.all.map(\.name).sorted() == Self.expectedTools.sorted())
    }

    @Test
    func `only index may write`() {
        // The read-only promise is the entire security argument for exposing
        // this to an autonomous agent.
        let writers = MCPToolCatalog.all.filter(\.writes).map(\.name)
        #expect(writers == ["index"])
    }

    @Test
    func `every tool advertises a strict object schema`() {
        for tool in MCPToolCatalog.all {
            let schema = try! #require(tool.inputSchema.objectValue, "\(tool.name) needs an object schema")
            #expect(schema["type"]?.stringValue == "object", "\(tool.name)")
            #expect(schema["additionalProperties"]?.boolValue == false, "\(tool.name) must reject unknown arguments")
            #expect(schema["properties"]?.objectValue != nil, "\(tool.name)")
        }
    }

    @Test
    func `every tool has a non-empty description`() {
        // An agent picks tools by description; a blank one is a broken tool.
        for tool in MCPToolCatalog.all {
            #expect(!tool.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(tool.name)")
            #expect(!tool.title.isEmpty, "\(tool.name)")
        }
    }

    @Test
    func `tools requiring an identifier declare it required`() {
        for name in ["read", "links", "context"] {
            let tool = try! #require(MCPToolCatalog.tool(named: name))
            let required = tool.inputSchema.objectValue?["required"]?
                .objectValueArrayStrings ?? []
            #expect(required.contains("path"), "\(name) must require path")
        }
        let search = try! #require(MCPToolCatalog.tool(named: "search"))
        #expect(search.inputSchema.objectValue?["required"]?.objectValueArrayStrings == ["query"])
    }

    @Test
    func `listing annotates read-only tools`() {
        let listing = try! #require(MCPToolCatalog.listing().arrayValue)
        #expect(listing.count == Self.expectedTools.count)
        for entry in listing {
            let object = try! #require(entry.objectValue)
            let name = try! #require(object["name"]?.stringValue)
            let readOnly = object["annotations"]?.objectValue?["readOnlyHint"]?.boolValue
            #expect(readOnly == (name != "index"), "\(name) readOnlyHint")
            // Nothing here deletes user content — not even `index`, which only
            // rebuilds derived rows.
            #expect(object["annotations"]?.objectValue?["destructiveHint"]?.boolValue == false, "\(name)")
        }
    }

    @Test
    func `unknown tool lookup returns nil rather than a default`() {
        #expect(MCPToolCatalog.tool(named: "delete_everything") == nil)
        #expect(MCPToolCatalog.tool(named: "") == nil)
    }
}

/// Bounds are shared with the HTTP layer, so an agent and a client cannot be
/// granted different limits for the same operation.
struct MCPLimitsTests {
    @Test
    func `a value inside the range passes through unchanged`() throws {
        #expect(try MCPLimits.validate(10, name: "limit", maximum: 50) == 10)
    }

    @Test
    func `out-of-range values are rejected, not clamped`() {
        // Clamping would let an agent ask for 5000 and silently receive 50
        // without ever learning the ceiling.
        #expect(throws: MCPError.self) { try MCPLimits.validate(0, name: "limit", maximum: 50) }
        #expect(throws: MCPError.self) { try MCPLimits.validate(51, name: "limit", maximum: 50) }
        #expect(throws: MCPError.self) { try MCPLimits.validate(-1, name: "limit", maximum: 50) }
    }

    @Test
    func `context sibling bounds match the HTTP service`() {
        #expect(MCPLimits.maxContextSiblingLimit == VaultNavigationService.maxSiblingLimit)
        #expect(MCPLimits.defaultContextSiblingLimit == VaultNavigationService.defaultSiblingLimit)
    }
}

/// JSON-RPC error codes are part of the wire contract.
struct MCPErrorCodeTests {
    @Test
    func `codes match the JSON-RPC specification`() {
        #expect(MCPError.parseError("x").body.code == -32700)
        #expect(MCPError.invalidRequest("x").body.code == -32600)
        #expect(MCPError.methodNotFound("x").body.code == -32601)
        #expect(MCPError.invalidParams("x").body.code == -32602)
        #expect(MCPError.internalError("x").body.code == -32603)
    }
}

/// `JSONValue` is what carries every argument and every result.
struct JSONValueTests {
    @Test
    func `round-trips through JSON unchanged`() throws {
        let original = JSONValue.object([
            "a": .string("x"),
            "b": .number(2),
            "c": .bool(true),
            "d": .null,
            "e": .array([.number(1), .string("two")]),
            "f": .object(["nested": .bool(false)]),
        ])
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(JSONValue.self, from: data) == original)
    }

    @Test
    func `encoding an Encodable produces a readable structure`() throws {
        struct Sample: Encodable { let path: String; let line: Int }
        let value = try JSONValue.encoding(Sample(path: "a.md", line: 7))
        #expect(value.objectValue?["path"]?.stringValue == "a.md")
        #expect(value.objectValue?["line"]?.intValue == 7)
    }

    @Test
    func `typed accessors return nil for the wrong shape`() {
        #expect(JSONValue.string("x").intValue == nil)
        #expect(JSONValue.number(1).stringValue == nil)
        #expect(JSONValue.null.objectValue == nil)
    }
}

// MARK: - Test helpers

private extension JSONValue {
    var arrayValue: [JSONValue]? {
        if case let .array(value) = self { return value }
        return nil
    }

    /// String contents of an array value, for schema `required` lists.
    var objectValueArrayStrings: [String]? {
        arrayValue?.compactMap(\.stringValue)
    }
}
