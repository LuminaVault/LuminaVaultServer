import FluentPostgresDriver
import Foundation
import Logging

/// Retries the boot-time database work when Postgres drops the connection.
///
/// A deploy runs the `api-migrate` Job (pg_dump, then migrations) right before
/// the new pod starts. Its first connection is sometimes reset as that work
/// winds down, and without a retry the error reached the top level, the
/// process trapped, and Kubernetes restarted the pod — every deploy began with
/// a crash. Only connection-level failures are retried: a failed migration or
/// bad credentials must still stop the boot on the first attempt.
enum StartupRetry {
    static let defaultDelays: [Duration] = [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(15)]

    static func run<T: Sendable>(
        _ label: String,
        delays: [Duration] = defaultDelays,
        logger: Logger,
        isTransient: @Sendable (any Error) -> Bool = isTransientConnectionError,
        sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        _ body: @Sendable () async throws -> T
    ) async throws -> T {
        var attempt = 0
        while true {
            do {
                return try await body()
            } catch where isTransient(error) && attempt < delays.count {
                let delay = delays[attempt]
                attempt += 1
                logger.warning(
                    "\(label) lost its database connection; retrying",
                    metadata: ["attempt": "\(attempt)", "delay": "\(delay)", "error": "\(String(reflecting: error))"]
                )
                try await sleep(delay)
            }
        }
    }

    static func isTransientConnectionError(_ error: any Error) -> Bool {
        guard let psql = error as? PSQLError else { return false }
        return psql.code == .connectionError
            || psql.code == .serverClosedConnection
            || psql.code == .uncleanShutdown
    }
}
