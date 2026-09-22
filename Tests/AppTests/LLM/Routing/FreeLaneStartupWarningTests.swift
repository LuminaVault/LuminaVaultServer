@testable import App
import Testing

/// A lane switched on with no platform key answers every request it takes with
/// `free_lane_unavailable`. That is a deploy mistake, and it should be heard at
/// boot, not from the first user's 503.
struct FreeLaneStartupWarningTests {
    @Test
    func `an enabled lane with no platform key warns`() {
        #expect(FreeLaneRuntime.startupWarning(enabled: true, openRouterEnabled: false, nvidiaEnabled: false) != nil)
    }

    @Test
    func `one loaded leg is enough to stay quiet`() {
        #expect(FreeLaneRuntime.startupWarning(enabled: true, openRouterEnabled: true, nvidiaEnabled: false) == nil)
        #expect(FreeLaneRuntime.startupWarning(enabled: true, openRouterEnabled: false, nvidiaEnabled: true) == nil)
    }

    @Test
    func `a disabled lane never warns`() {
        #expect(FreeLaneRuntime.startupWarning(enabled: false, openRouterEnabled: false, nvidiaEnabled: false) == nil)
    }
}
