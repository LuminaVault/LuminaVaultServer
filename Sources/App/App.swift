import Configuration
import Hummingbird
import Logging
#if canImport(PostHog)
    import PostHog
#endif

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

        let postHogToken = reader.string(forKey: "posthog.projectToken", default: "")
        let postHogHost = reader.string(forKey: "posthog.host", default: "")
        #if canImport(PostHog)
            if !postHogToken.isEmpty, !postHogHost.isEmpty {
                let postHogConfig = PostHogConfig(projectToken: postHogToken, host: postHogHost)
                PostHogSDK.shared.setup(postHogConfig)
            } else {
                Logger(label: "lv.posthog").warning("PostHog is not configured; analytics events will not be sent")
            }
        #else
            // Darwin-only SDK; Linux uses the OTel log pipeline (HER-236).
            _ = postHogToken
            _ = postHogHost
        #endif

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
            case "backfill-vault-space-folders":
                try await runBackfillVaultSpaceFoldersCommand(reader: reader)
                return
            default:
                break
            }
        }

        let app = try await buildApplication(reader: reader)
        try await app.runService()
    }
}
