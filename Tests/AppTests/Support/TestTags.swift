import Testing

extension Tag {
    /// Postgres-backed suites that boot `buildApplication` or `withTestFluent`.
    @Tag static var integration: Self
}
