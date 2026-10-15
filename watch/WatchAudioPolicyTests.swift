import Foundation

@main
struct WatchAudioPolicyTests {
    static func main() {
        // Losing headphones must never redirect playback to the speaker.
        precondition(WatchAudioPolicy.mustStop(routeReason: 2, hasOutput: true))
        for reason in [UInt(0), 1, 3, 4, 6, 7, 8] {
            precondition(!WatchAudioPolicy.mustStop(routeReason: reason, hasOutput: true))
            precondition(WatchAudioPolicy.mustStop(routeReason: reason, hasOutput: false))
        }
        print("Watch route transition checks passed")
    }
}
