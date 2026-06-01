import Foundation

/// HER-54 (Slice 1) — boot-time map of catalog `binding` keys to their
/// `CaptureHook` implementation, mirroring `ConnectorRegistry`.
/// `CaptureHookDispatcher` resolves a hook here for each enabled
/// `.captureHook` install.
struct CaptureHookRegistry {
    private let byBinding: [String: any CaptureHook]

    init(hooks: [any CaptureHook]) {
        var map: [String: any CaptureHook] = [:]
        for hook in hooks {
            map[hook.binding] = hook
        }
        byBinding = map
    }

    func hook(binding: String) -> (any CaptureHook)? {
        byBinding[binding]
    }
}
