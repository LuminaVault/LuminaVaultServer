@testable import App
import Configuration
import Hummingbird
import HummingbirdTesting
import Logging
import Testing

struct AppTests {
    @Test
    func `hello route serves`() async throws {
        let app = try await buildApplication(reader: noDBTestReader)
        try await app.test(.router) { client in
            try await client.execute(uri: "/", method: .get) { response in
                #expect(response.body == ByteBuffer(string: "Hello!"))
            }
        }
    }

    @Test
    func `health route returns OK`() async throws {
        let app = try await buildApplication(reader: noDBTestReader)
        try await app.test(.router) { client in
            try await client.execute(uri: "/health", method: .get) { response in
                #expect(response.status == .ok)
                #expect(response.body == ByteBuffer(string: "ok"))
            }
        }
    }
}
