import Foundation
import Hummingbird
import Logging

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Shape of `/2/users/me` response we care about. X returns a `data`
/// envelope; nested fields are the user record.
struct XUserResponse: Decodable {
    let data: XUserData

    struct XUserData: Decodable {
        let id: String
        let name: String
        let username: String
        let email: String? // requires `email` scope; may be missing
        let verified: Bool?
    }
}

protocol XAPIClient: Sendable {
    /// Verifies a bearer access_token by hitting `/2/users/me` and returns
    /// the X user. iOS handles the OAuth 2.0 + PKCE token exchange itself;
    /// we only consume the resulting access_token.
    func fetchMe(accessToken: String) async throws -> XUserResponse.XUserData
}

struct DefaultXAPIClient: XAPIClient {
    let session: URLSession
    let logger: Logger

    init(session: URLSession = .shared, logger: Logger) {
        self.session = session
        self.logger = logger
    }

    func fetchMe(accessToken: String) async throws -> XUserResponse.XUserData {
        let url = URL(string: "https://api.x.com/2/users/me?user.fields=id,name,username,verified,verified_email")!
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw HTTPError(.badGateway, message: "x: no http response")
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            let preview = String(data: data.prefix(512), encoding: .utf8) ?? "<binary>"
            logger.error("x users/me \(http.statusCode): \(preview)")
            throw HTTPError(.unauthorized, message: "x access_token rejected")
        }
        return try JSONDecoder().decode(XUserResponse.self, from: data).data
    }
}
