@testable import App
import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import HummingbirdTesting
import LuminaVaultShared
import Testing

/// The memory tools let an outside agent save, correct and forget what the
/// user wants remembered across sessions. What has to hold: a read-only key
/// cannot write, every write says which key made it, a correction or a forget
/// is what later searches see, and no key reaches another account's memories.
///
/// Run with `docker compose up -d postgres`.
@Suite(.serialized, .tags(.integration), .integrationDatabase, .disabled(if: IntegrationTestEnv.skipIntegration))
struct MCPMemoryToolsTests {
    private struct Account {
        let userID: UUID
        let jwt: String
    }

    private static func register(client: some TestClientProtocol) async throws -> Account {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        let body = ByteBuffer(
            string: #"{"email":"mcpmem-\#(suffix)@test.luminavault","username":"mcpmem\#(suffix)","password":"CorrectHorseBatteryStaple1!"}"#
        )
        let auth = try await client.execute(
            uri: "/v1/auth/register",
            method: .post,
            headers: [.contentType: "application/json"],
            body: body
        ) { try testJSONDecoder().decode(AuthResponse.self, from: Data($0.body.readableBytesView)) }
        return Account(userID: auth.userId, jwt: auth.accessToken)
    }

    private static func issueKey(
        client: some TestClientProtocol,
        account: Account,
        name: String,
        access: AgentConnectionAccess
    ) async throws -> String {
        let body = #"{"name":"\#(name)","clientKind":"codex","access":"\#(access.rawValue)"}"#
        return try await client.execute(
            uri: "/v1/me/agent-connections",
            method: .post,
            headers: [.authorization: "Bearer \(account.jwt)", .contentType: "application/json"],
            body: ByteBuffer(string: body)
        ) { try testJSONDecoder().decode(AgentConnectionIssuedResponse.self, from: Data($0.body.readableBytesView)).token }
    }

    /// One `tools/call`, returning the JSON-RPC envelope as a dictionary.
    private static func call(
        client: some TestClientProtocol,
        token: String,
        tool: String,
        arguments: [String: Any]
    ) async throws -> [String: Any] {
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": ["name": tool, "arguments": arguments],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try await client.execute(
            uri: "/v1/mcp",
            method: .post,
            headers: [.authorization: "Bearer \(token)", .contentType: "application/json"],
            body: ByteBuffer(data: data)
        ) { response in
            #expect(response.status == .ok)
            let object = try JSONSerialization.jsonObject(with: Data(response.body.readableBytesView))
            return try #require(object as? [String: Any])
        }
    }

    /// The tool's own result object, or nil when the call failed at the protocol level.
    private static func result(_ envelope: [String: Any]) -> [String: Any]? {
        (envelope["result"] as? [String: Any])?["structuredContent"] as? [String: Any]
    }

    private static func searchTexts(
        client: some TestClientProtocol,
        token: String,
        query: String,
        space: String? = nil
    ) async throws -> [String] {
        var arguments: [String: Any] = ["query": query]
        if let space {
            arguments["space"] = space
        }
        let envelope = try await call(client: client, token: token, tool: "search", arguments: arguments)
        let rows = result(envelope)?["results"] as? [[String: Any]] ?? []
        return rows.compactMap { $0["text"] as? String }
    }

    @Test
    func `a read-only key cannot save a memory`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let account = try await Self.register(client: client)
            let token = try await Self.issueKey(client: client, account: account, name: "ro", access: .read)
            let envelope = try await Self.call(
                client: client, token: token, tool: "memory_save", arguments: ["content": "Prefers tabs."]
            )
            let result = try #require(Self.result(envelope))
            #expect(result["isError"] as? Bool == true)
            #expect((result["message"] as? String ?? "").contains("read-only"))
        }
    }

    @Test
    func `a saved memory is searchable and says which key saved it`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let account = try await Self.register(client: client)
            let token = try await Self.issueKey(client: client, account: account, name: "work laptop", access: .readWrite)

            let saved = try #require(try await Self.result(Self.call(
                client: client, token: token, tool: "memory_save",
                arguments: ["content": "Prefers Python for scripting. Codeword quuxpython.", "tags": ["lang"]]
            )))
            #expect(saved["duplicate"] as? Bool == false)
            let memoryID = try #require((saved["memoryID"] as? String).flatMap(UUID.init(uuidString:)))

            let texts = try await Self.searchTexts(client: client, token: token, query: "quuxpython")
            #expect(texts.contains { $0.contains("quuxpython") })

            let provenance: MemoryProvenanceResponse = try await client.execute(
                uri: "/v1/memory/\(memoryID)/provenance",
                method: .get,
                headers: [.authorization: "Bearer \(account.jwt)"]
            ) { try testJSONDecoder().decode(MemoryProvenanceResponse.self, from: Data($0.body.readableBytesView)) }
            let created = try #require(provenance.contributions.first)
            #expect(created.actor == .model)
            #expect(created.model?.provider == "mcp:codex")
            #expect(created.model?.model == "work laptop")
            #expect(created.sourceReference?.hasPrefix("agent_connection:") == true)

            let memory: MemoryDTO = try await client.execute(
                uri: "/v1/memory/\(memoryID)",
                method: .get,
                headers: [.authorization: "Bearer \(account.jwt)"]
            ) { try testJSONDecoder().decode(MemoryDTO.self, from: Data($0.body.readableBytesView)) }
            #expect(memory.createdByUserId == account.userID)
            #expect(memory.tags == ["lang"])

            // An exact repeat is the same memory, not a second one.
            let again = try #require(try await Self.result(Self.call(
                client: client, token: token, tool: "memory_save",
                arguments: ["content": "Prefers Python for scripting. Codeword quuxpython."]
            )))
            #expect(again["duplicate"] as? Bool == true)
            #expect(again["memoryID"] as? String == memoryID.uuidString)
        }
    }

    @Test
    func `update replaces what search sees and forget removes it`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let account = try await Self.register(client: client)
            let token = try await Self.issueKey(client: client, account: account, name: "rw", access: .readWrite)
            let saved = try #require(try await Self.result(Self.call(
                client: client, token: token, tool: "memory_save",
                arguments: ["content": "Deploys on Fridays. Codeword quuxfriday."]
            )))
            let memoryID = try #require(saved["memoryID"] as? String)

            let updated = try #require(try await Self.result(Self.call(
                client: client, token: token, tool: "memory_update",
                arguments: ["memoryID": memoryID, "content": "Never deploys on Fridays. Codeword quuxmonday."]
            )))
            #expect(updated["updated"] as? Bool == true)
            #expect(try await !Self.searchTexts(client: client, token: token, query: "quuxfriday")
                .contains { $0.contains("quuxfriday") })
            #expect(try await Self.searchTexts(client: client, token: token, query: "quuxmonday")
                .contains { $0.contains("quuxmonday") })

            let forgotten = try #require(try await Self.result(Self.call(
                client: client, token: token, tool: "memory_forget", arguments: ["memoryID": memoryID]
            )))
            #expect(forgotten["forgotten"] as? Bool == true)
            try await client.execute(
                uri: "/v1/memory/\(memoryID)",
                method: .get,
                headers: [.authorization: "Bearer \(account.jwt)"]
            ) { #expect($0.status == .notFound) }
        }
    }

    @Test
    func `a key cannot touch another account's memories`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let owner = try await Self.register(client: client)
            let ownerToken = try await Self.issueKey(client: client, account: owner, name: "owner", access: .readWrite)
            let saved = try #require(try await Self.result(Self.call(
                client: client, token: ownerToken, tool: "memory_save", arguments: ["content": "Owner's secret plan."]
            )))
            let memoryID = try #require(saved["memoryID"] as? String)

            let other = try await Self.register(client: client)
            let otherToken = try await Self.issueKey(client: client, account: other, name: "other", access: .readWrite)
            for (tool, arguments) in [
                ("memory_update", ["memoryID": memoryID, "content": "hijacked"]),
                ("memory_forget", ["memoryID": memoryID]),
            ] {
                let result = try #require(try await Self.result(Self.call(
                    client: client, token: otherToken, tool: tool, arguments: arguments
                )))
                #expect(result["isError"] as? Bool == true, "\(tool) must not reach another account")
            }

            let memory: MemoryDTO = try await client.execute(
                uri: "/v1/memory/\(memoryID)",
                method: .get,
                headers: [.authorization: "Bearer \(owner.jwt)"]
            ) { try testJSONDecoder().decode(MemoryDTO.self, from: Data($0.body.readableBytesView)) }
            #expect(memory.content == "Owner's secret plan.")
        }
    }

    @Test
    func `a memory can be filed in a Space and searched within it`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let account = try await Self.register(client: client)
            let token = try await Self.issueKey(client: client, account: account, name: "rw", access: .readWrite)
            try await withTestFluent(label: "test.mcp.memory.space") { fluent in
                let space = Space(tenantID: account.userID, name: "Work", slug: "work")
                try await space.save(on: fluent.db())
                let spaceID = try space.requireID()

                let saved = try #require(try await Self.result(Self.call(
                    client: client, token: token, tool: "memory_save",
                    arguments: ["content": "Standup is at 9. Codeword quuxstandup.", "space": "work"]
                )))
                let memoryID = try #require((saved["memoryID"] as? String).flatMap(UUID.init(uuidString:)))
                let row = try #require(try await MemoryRepository(fluent: fluent).find(tenantID: account.userID, id: memoryID))
                #expect(row.spaceID == spaceID)

                #expect(try await Self.searchTexts(client: client, token: token, query: "quuxstandup", space: "work")
                    .contains { $0.contains("quuxstandup") })

                // A Space that does not exist is a readable error, not a silent inbox save.
                let envelope = try await Self.call(
                    client: client, token: token, tool: "memory_save",
                    arguments: ["content": "x", "space": "nope"]
                )
                let error = try #require(envelope["error"] as? [String: Any])
                #expect((error["message"] as? String ?? "").contains("unknown space 'nope'"))
            }
        }
    }

    @Test
    func `hiding the model leaves an agent key's attribution visible`() {
        let agent = MemoryContributionDTO(
            id: UUID(), operation: .create, actor: .model, source: .manual,
            model: ModelProvenanceDTO(provider: "mcp:codex", model: "laptop"),
            sourceReference: nil, createdAt: Date()
        )
        let upstream = MemoryContributionDTO(
            id: UUID(), operation: .create, actor: .model, source: .chat,
            model: ModelProvenanceDTO(provider: "openrouter", model: "some-vendor-model"),
            sourceReference: nil, createdAt: Date()
        )
        #expect(ModelDisclosurePolicy.scrub(agent, disclosure: .hidden).model?.model == "laptop")
        #expect(ModelDisclosurePolicy.scrub(upstream, disclosure: .hidden).model == nil)
    }

    @Test
    func `the catalog marks correcting and forgetting as destructive`() {
        guard case let .array(listing) = MCPToolCatalog.listing() else {
            Issue.record("tools/list must be an array")
            return
        }
        func annotations(_ name: String) -> [String: JSONValue]? {
            listing.first { $0.objectValue?["name"]?.stringValue == name }?
                .objectValue?["annotations"]?.objectValue
        }
        #expect(annotations("memory_save")?["readOnlyHint"]?.boolValue == false)
        #expect(annotations("memory_save")?["destructiveHint"]?.boolValue == false)
        #expect(annotations("memory_update")?["destructiveHint"]?.boolValue == true)
        #expect(annotations("memory_forget")?["destructiveHint"]?.boolValue == true)
        #expect(annotations("search")?["readOnlyHint"]?.boolValue == true)
    }
}
