@testable import App
import Foundation
import Testing

/// Origin parsing for WebAuthn.
///
/// The relying-party ID `luminavault.fyi` is shared by two origins — the web
/// app at `https://app.luminavault.fyi` and iOS native, which presents
/// `https://luminavault.fyi`. One configured string cannot serve both, so the
/// value became a list. A single value must keep behaving exactly as it does
/// today: that is what every current deployment has.
struct WebAuthnOriginsTests {
    @Test
    func `a single origin parses to one entry`() {
        #expect(WebAuthnService.parseOrigins("https://api.luminavault.fyi") == ["https://api.luminavault.fyi"])
    }

    @Test
    func `a comma separated list parses in order`() {
        #expect(
            WebAuthnService.parseOrigins("https://app.luminavault.fyi,https://luminavault.fyi")
                == ["https://app.luminavault.fyi", "https://luminavault.fyi"]
        )
    }

    /// A trailing comma or a stray space is the kind of thing that reaches a
    /// sealed secret and is never seen again. An empty entry would build a
    /// manager configured with an empty origin, which fails every ceremony
    /// with an error that says nothing about the real cause.
    @Test
    func `blank and whitespace-padded entries are dropped`() {
        #expect(
            WebAuthnService.parseOrigins(" https://a.example , ,https://b.example, ")
                == ["https://a.example", "https://b.example"]
        )
    }

    @Test
    func `an empty configuration parses to no origins`() {
        #expect(WebAuthnService.parseOrigins("") == [])
        #expect(WebAuthnService.parseOrigins("   ") == [])
        #expect(WebAuthnService.parseOrigins(",,") == [])
    }

    /// Duplicates would make the service verify the same origin twice on every
    /// failed ceremony, for nothing.
    @Test
    func `duplicates collapse while preserving first-seen order`() {
        #expect(
            WebAuthnService.parseOrigins("https://b.example,https://a.example,https://b.example")
                == ["https://b.example", "https://a.example"]
        )
    }
}
