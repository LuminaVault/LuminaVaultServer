# PostHog post-wizard report

PostHog has been integrated into the Swift server package with the `PostHog` Swift Package Manager dependency. Startup now reads `POSTHOG_PROJECT_TOKEN` and `POSTHOG_HOST` through the existing configuration reader, then initializes the SDK once. The public project token and ingestion host were added to `.env` and `.env.example`.

The integration adds privacy-conscious server-side product events for successful actions only. Event properties contain aggregate counts, booleans, and non-sensitive operational metadata; no user-entered content, emails, names, URLs, file paths, identifiers, or device tokens are captured.

| Event name | Description | File |
| --- | --- | --- |
| `user_registered` | Successful password-based account registration. | `Sources/App/Auth/AuthController.swift` |
| `user_logged_in` | Successful password-based login. | `Sources/App/Auth/AuthController.swift` |
| `vault_file_uploaded` | Successful vault upload with file type and workflow metadata. | `Sources/App/Vault/VaultController.swift` |
| `vault_file_deleted` | Successful vault-file deletion. | `Sources/App/Vault/VaultController.swift` |
| `link_captured` | Successful Safari share-flow link capture. | `Sources/App/Capture/CaptureController.swift` |
| `calendar_connected` | Successful start of Google Calendar authorization. | `Sources/App/Calendar/CalendarController.swift` |
| `calendar_event_created` | Successful Google Calendar event creation. | `Sources/App/Calendar/CalendarController.swift` |
| `health_events_synced` | Successful HealthKit batch ingestion using aggregate counts. | `Sources/App/Health/HealthIngestController.swift` |
| `apple_data_consent_updated` | Apple data-access consent change. | `Sources/App/Apple/AppleConsentController.swift` |
| `apple_calendar_synced` | Successful Apple Calendar sync with aggregate counts. | `Sources/App/Calendar/AppleCalendarController.swift` |
| `apple_reminders_synced` | Successful Apple Reminders sync with aggregate counts. | `Sources/App/Apple/AppleRemindersController.swift` |
| `photos_indexed` | Successful derived-text photo indexing with aggregate counts. | `Sources/App/Apple/PhotoIndexController.swift` |

## Next steps

A dashboard and four saved insights were created for the newly instrumented signals:

- [Analytics basics (wizard)](https://eu.posthog.com/project/227780/dashboard/832701)
- [Account activation (wizard)](https://eu.posthog.com/project/227780/insights/FL2bQJmR)
- [Vault usage (wizard)](https://eu.posthog.com/project/227780/insights/cvLeSKBd)
- [Connected-data syncs (wizard)](https://eu.posthog.com/project/227780/insights/SVpcjhYb)
- [Calendar adoption (wizard)](https://eu.posthog.com/project/227780/insights/Okmd1Dav)

## Verify before merging

- [ ] Run a full production build (the wizard only verified the files it touched) and fix any lint or type errors introduced by the generated code.
- [ ] Run the test suite — call sites that were rewritten or instrumented may need updated mocks or fixtures.
- [ ] Confirm `POSTHOG_PROJECT_TOKEN` and `POSTHOG_HOST` are available in each deployment environment that does not load the repository `.env` file.

### Agent skill

The repository contains the installed `integration-swift` agent skill under `.claude/skills/` for future PostHog development work.
