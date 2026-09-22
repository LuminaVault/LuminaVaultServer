@testable import App
import Foundation
import Testing

/// Google Calendar connect from the web: where the callback sends the
/// browser, and why it can never be off-site.
struct CalendarWebReturnTests {
    private static let allowed: Set<String> = ["https://app.luminavault.fyi", "http://localhost:5173"]

    @Test
    func `a page on an allowed origin is accepted as is`() {
        let url = "https://app.luminavault.fyi/settings/integrations?tab=calendar"
        #expect(GoogleCalendarOAuthService.validatedReturn(url, allowedOrigins: Self.allowed) == url)
        #expect(GoogleCalendarOAuthService.validatedReturn("http://localhost:5173/settings", allowedOrigins: Self.allowed) != nil)
        // Origins compare case-insensitively and ignore a trailing slash in config.
        #expect(GoogleCalendarOAuthService.validatedReturn("https://APP.luminavault.fyi/x", allowedOrigins: ["https://app.luminavault.fyi/"]) != nil)
    }

    @Test
    func `anything off the allow-list is refused`() {
        for bad in [
            "https://evil.example/settings",
            "https://app.luminavault.fyi.evil.example/",
            "https://user:pw@app.luminavault.fyi/",
            "https://app.luminavault.fyi/#frag",
            "http://app.luminavault.fyi/", // scheme is part of the origin
            "https://app.luminavault.fyi:8443/",
            "javascript:alert(1)",
            "/settings",
            "luminavault://oauth/google-calendar",
        ] {
            #expect(GoogleCalendarOAuthService.validatedReturn(bad, allowedOrigins: Self.allowed) == nil, "\(bad)")
        }
        // An empty allow-list (dev) accepts no web return at all.
        #expect(GoogleCalendarOAuthService.validatedReturn("https://app.luminavault.fyi/", allowedOrigins: []) == nil)
    }

    @Test
    func `the redirect appends status and reason to the return page`() {
        #expect(GoogleCalendarOAuthService.redirect(base: "https://app.luminavault.fyi/settings", status: "ok", reason: nil)
            == "https://app.luminavault.fyi/settings?status=ok")
        #expect(GoogleCalendarOAuthService.redirect(base: "https://app.luminavault.fyi/s?tab=cal", status: "error", reason: "access_denied")
            == "https://app.luminavault.fyi/s?tab=cal&status=error&reason=access_denied")
        #expect(GoogleCalendarOAuthService.redirect(base: GoogleCalendarOAuthService.appCallbackBase, status: "ok", reason: nil)
            == "luminavault://oauth/google-calendar?status=ok")
    }
}
