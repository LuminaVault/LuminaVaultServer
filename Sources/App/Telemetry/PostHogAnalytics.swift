#if canImport(PostHog)
    import PostHog

    enum PostHogAnalytics {
        static func capture(_ event: String, properties: [String: Any] = [:]) {
            PostHogSDK.shared.capture(event, properties: properties)
        }
    }
#else
    /// PostHog's SDK is Darwin-only (ObjC Foundation headers); Linux deploys
    /// ship the OTel → otel-collector → PostHog pipeline instead (HER-236).
    enum PostHogAnalytics {
        static func capture(_: String, properties _: [String: Any] = [:]) {}
    }
#endif
