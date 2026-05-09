import Configuration
import Hummingbird
import HummingbirdTesting
import Logging
import Testing

@testable import App

@Suite
struct AppTests {
    @Test
    func helloRouteServes() async throws {
        let app = try await buildApplication(reader: noDBTestReader)
        try await app.test(.router) { client in
            try await client.execute(uri: "/", method: .get) { response in
                #expect(response.body == ByteBuffer(string: "Hello!"))
            }
        }
    }

    @Test
    func healthRouteReturnsOK() async throws {
        let app = try await buildApplication(reader: noDBTestReader)
        try await app.test(.router) { client in
            try await client.execute(uri: "/health", method: .get) { response in
                #expect(response.status == .ok)
                #expect(response.body == ByteBuffer(string: "ok"))
            }
        }
    }
}
