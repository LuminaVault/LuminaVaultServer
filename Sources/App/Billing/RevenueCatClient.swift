import Foundation
import Hummingbird
import Logging

struct RevenueCatClient {
    let baseURL: URL
    let apiKey: String
    let session: URLSession
    let logger: Logger

    init(
        baseURL: URL = URL(string: "https://api.revenuecat.com/v1")!,
        apiKey: String,
        session: URLSession = .shared,
        logger: Logger = Logger(label: "lv.billing.revenuecat-client"),
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.session = session
        self.logger = logger
    }

    // Additional methods for fetching single user later when needed by Ops/Admin endpoints
}
