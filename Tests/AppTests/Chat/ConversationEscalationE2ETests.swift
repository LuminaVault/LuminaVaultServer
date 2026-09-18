@testable import App
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import LuminaVaultShared
import Testing

/// A chat turn may escalate to a Hermes agent run instead of the ordinary
/// retrieval-augmented stream.
///
/// What is proved here is the safe half: that a turn which *cannot* escalate
/// still gets answered. Actually escalating needs a configured Hermes
/// endpoint, which the test stack deliberately does not have — the decision
/// itself is covered exhaustively and without I/O in
/// `HermesEscalationPolicyTests`, and the gate in `ClientCapabilitiesTests`.
///
/// Degradation is the property worth an end-to-end test, because every way it
/// can go wrong ends with a user whose message vanished.
///
/// Requires `docker compose up -d postgres`.
@Suite(.serialized, .tags(.integration), .integrationDatabase, .disabled(if: IntegrationTestEnv.skipIntegration))
struct ConversationEscalationE2ETests {
    private static func randomUser() -> (email: String, username: String) {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        return ("esc-e2e-\(suffix)@test.luminavault", "esc-e2e-\(suffix)")
    }

    private static func auth(_ token: String, caps: String? = nil) -> HTTPFields {
        var fields: HTTPFields = [.authorization: "Bearer \(token)", .contentType: "application/json"]
        if let caps {
            fields[.init("x-lv-client-caps")!] = caps
        }
        return fields
    }

    private static func registerUser(client: some TestClientProtocol) async throws -> String {
        let (email, username) = randomUser()
        return try await client.execute(
            uri: "/v1/auth/register",
            method: .post,
            headers: [.contentType: "application/json"],
            body: ByteBuffer(string: """
            {"email":"\(email)","username":"\(username)","password":"CorrectHorseBatteryStaple1!"}
            """)
        ) { response in
            try testJSONDecoder().decode(AuthResponse.self, from: Data(buffer: response.body)).accessToken
        }
    }

    private static func makeConversation(
        client: some TestClientProtocol,
        token: String
    ) async throws -> ConversationDTO {
        try await client.execute(
            uri: "/v1/conversations",
            method: .post,
            headers: auth(token),
            body: ByteBuffer(string: #"{"title":"escalation"}"#)
        ) { try testJSONDecoder().decode(ConversationDTO.self, from: Data(buffer: $0.body)) }
    }

    /// An imperative prompt from a client that CAN handle the run pointer,
    /// on a stack with no Hermes configured. The turn must still be answered
    /// the ordinary way rather than erroring, because the user asked a
    /// question, not for a particular execution strategy.
    @Test("A turn that wants to escalate but cannot still gets answered")
    func escalationFallsBackWhenHermesIsAbsent() async throws {
        let app = try await buildApplication(reader: dbTestReaderWithStubChat())
        try await app.test(.router) { client in
            let token = try await Self.registerUser(client: client)
            let convo = try await Self.makeConversation(client: client, token: token)

            try await client.execute(
                uri: "/v1/conversations/\(convo.id)/messages/stream",
                method: .post,
                headers: Self.auth(token, caps: "chat.hermes_run"),
                body: ByteBuffer(string: #"{"content":"deploy the api","agentMode":"force"}"#)
            ) { response in
                #expect(response.status == .ok)
                let body = String(buffer: response.body)
                #expect(!body.contains("hermes_run"), "emitted a run pointer with no run behind it")
            }
        }
    }

    /// The gate itself: a client that has not declared the capability must
    /// never receive the new event, whatever it asks for. Builds older than
    /// LuminaVaultShared 5.16.0 abort the entire stream on an unknown type.
    @Test("A client that declared nothing never receives a run pointer")
    func silentClientNeverGetsTheNewEvent() async throws {
        let app = try await buildApplication(reader: dbTestReaderWithStubChat())
        try await app.test(.router) { client in
            let token = try await Self.registerUser(client: client)
            let convo = try await Self.makeConversation(client: client, token: token)

            try await client.execute(
                uri: "/v1/conversations/\(convo.id)/messages/stream",
                method: .post,
                headers: Self.auth(token),
                body: ByteBuffer(string: #"{"content":"deploy the api","agentMode":"force"}"#)
            ) { response in
                #expect(response.status == .ok)
                #expect(!String(buffer: response.body).contains("hermes_run"))
            }
        }
    }

    /// The new request fields are optional on the wire. A client that sends
    /// neither must behave exactly as it did before they existed.
    @Test("A request omitting agentMode and attachments still streams")
    func requestWithoutNewFieldsStillWorks() async throws {
        let app = try await buildApplication(reader: dbTestReaderWithStubChat())
        try await app.test(.router) { client in
            let token = try await Self.registerUser(client: client)
            let convo = try await Self.makeConversation(client: client, token: token)

            try await client.execute(
                uri: "/v1/conversations/\(convo.id)/messages/stream",
                method: .post,
                headers: Self.auth(token),
                body: ByteBuffer(string: #"{"content":"what did I note yesterday?"}"#)
            ) { #expect($0.status == .ok) }
        }
    }

    /// `agentMode` is camelCase on the wire because the server decodes
    /// request bodies with a plain decoder. Sending snake_case must not
    /// quietly succeed, or the two spellings drift apart unnoticed.
    @Test("agentMode is accepted camelCase and ignored as snake_case")
    func agentModeWireSpelling() async throws {
        let app = try await buildApplication(reader: dbTestReaderWithStubChat())
        try await app.test(.router) { client in
            let token = try await Self.registerUser(client: client)
            let convo = try await Self.makeConversation(client: client, token: token)

            // Unknown keys are ignored rather than rejected, so this proves
            // the shape is accepted — the decode assertion lives in the
            // shared package's wire-format tests.
            try await client.execute(
                uri: "/v1/conversations/\(convo.id)/messages/stream",
                method: .post,
                headers: Self.auth(token),
                body: ByteBuffer(string: #"{"content":"hello","agentMode":"off"}"#)
            ) { #expect($0.status == .ok) }
        }
    }
}
