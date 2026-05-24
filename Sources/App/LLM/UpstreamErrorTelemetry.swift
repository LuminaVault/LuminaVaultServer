import Metrics

/// HER-240 — Per-reason-code counter for LLM upstream errors. Dashboards
/// group `luminavault.llm.chat.upstream_error` by the `code` dimension
/// to observe timeout vs unreachable vs rejected without parsing log
/// strings.
enum UpstreamErrorTelemetry {
    /// Emit one increment on the shared upstream-error counter.
    ///
    /// - Parameters:
    ///   - reasonCode: Machine-readable code (e.g. `"upstream_timeout"`).
    ///   - provider: Raw provider identifier (e.g. `"hermesGateway"`).
    ///   - factory: Metrics backend. Defaults to the process-global
    ///     `MetricsSystem.factory`; pass a stub in tests.
    static func record(
        reasonCode: String,
        provider: String,
        factory: MetricsFactory = MetricsSystem.factory,
    ) {
        Counter(
            label: "luminavault.llm.chat.upstream_error",
            dimensions: [
                ("code", reasonCode),
                ("provider", provider),
            ],
            factory: factory,
        ).increment()
    }
}
