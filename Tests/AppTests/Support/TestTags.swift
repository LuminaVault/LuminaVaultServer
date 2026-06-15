import Foundation
import Testing

extension Tag {
    /// Postgres-backed suites that boot `buildApplication` or `withTestFluent`.
    @Tag static var integration: Self
}

/// CI env gates for split unit vs integration jobs.
enum IntegrationTestEnv {
    /// Unit-test job sets `SKIP_INTEGRATION_TESTS=1`.
    static var skipIntegration: Bool {
        ProcessInfo.processInfo.environment["SKIP_INTEGRATION_TESTS"] == "1"
    }

    /// Integration job sets `RUN_INTEGRATION_ONLY=1`.
    static var runIntegrationOnly: Bool {
        ProcessInfo.processInfo.environment["RUN_INTEGRATION_ONLY"] == "1"
    }
}
