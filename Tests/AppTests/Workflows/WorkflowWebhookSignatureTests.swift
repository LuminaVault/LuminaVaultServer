@testable import App
import Foundation
import Testing

@Suite("Workflow webhook signatures")
struct WorkflowWebhookSignatureTests {
    @Test func acceptsExactBodyAndTimestamp() {
        let body = Data(#"{"event":"created"}"#.utf8)
        let signature = WorkflowWebhookSignature.sign(secret: "test-secret", timestamp: "1720000000", body: body)
        #expect(WorkflowWebhookSignature.verify(signature, secret: "test-secret", timestamp: "1720000000", body: body))
    }

    @Test func rejectsTamperedPayloadOrTimestamp() {
        let body = Data(#"{"event":"created"}"#.utf8)
        let signature = WorkflowWebhookSignature.sign(secret: "test-secret", timestamp: "1720000000", body: body)
        #expect(!WorkflowWebhookSignature.verify(signature, secret: "test-secret", timestamp: "1720000001", body: body))
        #expect(!WorkflowWebhookSignature.verify(signature, secret: "test-secret", timestamp: "1720000000", body: Data("tampered".utf8)))
    }
}
