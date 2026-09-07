@testable import App
import Testing

/// The reaper's cadence. `evictIdle()` shipped in HER-240a documented as
/// "called periodically by a background service" and had no caller at all,
/// so every tenant container ever spawned stayed up holding a port from a
/// finite pool.
struct HermesContainerReaperServiceTests {
    /// A quarter of the idle TTL bounds how long a container can sit idle
    /// past its deadline to 25% of the window.
    @Test
    func `the interval is a quarter of the idle TTL`() {
        #expect(HermesContainerReaperService.intervalSeconds(idleTTLSeconds: 1800) == 450)
        #expect(HermesContainerReaperService.intervalSeconds(idleTTLSeconds: 3600) == 900)
    }

    /// A short TTL must not turn the reaper into a busy loop against Postgres.
    @Test
    func `the interval never drops below a minute`() {
        #expect(HermesContainerReaperService.intervalSeconds(idleTTLSeconds: 60) == 60)
        #expect(HermesContainerReaperService.intervalSeconds(idleTTLSeconds: 1) == 60)
        #expect(HermesContainerReaperService.intervalSeconds(idleTTLSeconds: 0) == 60)
    }
}
