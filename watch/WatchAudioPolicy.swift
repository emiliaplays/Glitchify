import Foundation

/// Only an actual output loss should end playback. Category/configuration
/// notifications also occur when we select a background-capable audio policy.
enum WatchAudioPolicy {
    static func mustStop(routeReason: UInt, hasOutput: Bool) -> Bool {
        routeReason == 2 || !hasOutput // oldDeviceUnavailable
    }
}
