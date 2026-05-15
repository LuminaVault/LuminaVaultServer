import Configuration
import Hummingbird
import Logging

@main
struct App {
    static func main() async throws {
        // Application will read configuration from the following in the order listed
        // Command line, Environment variables, dotEnv file, defaults provided in memory
        let reader = try await ConfigReader(providers: [
            CommandLineArgumentsProvider(),
            EnvironmentVariablesProvider(),
            EnvironmentVariablesProvider(environmentFilePath: ".env", allowMissing: true),
            InMemoryProvider(values: [
                "http.serverName": "ObsidianClaudeBrainServer",
            ]),
        ])

        // HER-29 — CLI subcommand support. First positional argument selects
        // a one-shot command instead of booting the HTTP server. Reuses the
        // same `ConfigReader` chain so secrets/DB config come from env/dotenv.
        if let subcommand = CommandLine.arguments.dropFirst().first(where: { !$0.hasPrefix("-") }) {
            switch subcommand {
            case "backfill-hermes-profiles":
                try await runBackfillHermesProfilesCommand(reader: reader)
                return
            case "migrate":
                try await runMigrateCommand(reader: reader)
                return
            case "bootstrap-admin":
                try await runBootstrapAdminCommand(reader: reader)
                return
            default:
                break
            }
        }

        let app = try await buildApplication(reader: reader)
        try await app.runService()
    }
}
