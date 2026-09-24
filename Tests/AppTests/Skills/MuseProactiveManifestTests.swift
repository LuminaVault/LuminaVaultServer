@testable import App
import Foundation
import Testing

/// Muse Chat stage C — which skills speak in the chat thread, and with what.
struct MuseProactiveManifestTests {
    private static func dailyBrief() throws -> SkillManifest {
        let url = try #require(Bundle.module.url(forResource: "SKILL", withExtension: "md", subdirectory: "Skills/daily-brief"))
        return try SkillManifestParser().parse(source: .builtin, contents: String(contentsOf: url, encoding: .utf8))
    }

    @Test
    func `chat_message is a manifest output kind`() throws {
        let md = """
        ---
        name: t
        description: t
        metadata:
          capability: low
          outputs:
            - kind: chat_message
        ---
        body
        """
        let manifest = try SkillManifestParser().parse(source: .vault, contents: md)
        #expect(manifest.outputs.map(\.kind) == [.chatMessage])
    }

    @Test
    func `the morning brief posts into the chat and can read weather and the inbox`() throws {
        let manifest = try Self.dailyBrief()
        #expect(manifest.outputs.map(\.kind) == [.memo, .chatMessage])
        // chat_message pushes on its own; a digest push as well would buzz twice.
        #expect(!manifest.outputs.contains { $0.kind == .apnsDigest })
        #expect(manifest.allowedTools.contains("weather_forecast"))
        #expect(manifest.allowedTools.contains("mail_inbox_recent"))
        #expect(manifest.body.contains("Inbox needs a look"))
        #expect(!manifest.body.contains("TODO"))
        #expect(manifest.schedule == "0 7 * * *")
    }

    @Test
    func `a new job answers in the chat thread`() throws {
        let md = JobAuthoring.skillMarkdown(
            slug: "job-dry-week", title: "Dry week watch", cron: "0 8 * * *", domain: "weather",
            spec: "Check the weather each morning; alert me when 5 consecutive dry days are coming."
        )
        let manifest = try SkillManifestParser().parse(source: .vault, contents: md)
        #expect(manifest.outputs.map(\.kind) == [.chatMessage])
        #expect(manifest.allowedTools.contains("weather_forecast"))
        #expect(manifest.allowedTools.contains("mail_inbox_recent"))
        #expect(manifest.allowedTools.contains("session_search"))
    }

    @Test
    func `the lock screen preview is the first plain line`() throws {
        #expect(ProactiveChatDelivery.preview("## Good morning\n\n- Dry week ahead") == "Good morning")
        #expect(ProactiveChatDelivery.preview("\n\n**Busy day.** Three meetings.") == "Busy day.** Three meetings.")
        let long = String(repeating: "a", count: 300)
        #expect(ProactiveChatDelivery.preview(long).count == 140)
        #expect(try ProactiveChatDelivery.deepLink(conversationID: #require(UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")))
            == "luminavault://chat/6F9619FF-8B86-D011-B42D-00C04FC964FF")
    }
}
