import PostHog

enum PostHogAnalytics {
    static func capture(_ event: String, properties: [String: Any] = [:]) {
        PostHogSDK.shared.capture(event, properties: properties)
    }
}
