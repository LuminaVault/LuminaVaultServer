import SQLKit

/// Runs a trusted, static migration script one statement at a time. PostgreSQL's
/// extended query protocol rejects multiple commands in one prepared statement.
func runMigrationScript(_ script: String, on sql: any SQLDatabase) async throws {
    for statement in script.split(separator: ";") where statement.contains(where: { !$0.isWhitespace }) {
        try await sql.raw(SQLQueryString(String(statement))).run()
    }
}
