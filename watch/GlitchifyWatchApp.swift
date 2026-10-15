import SwiftUI

@main
@MainActor
struct GlitchifyWatchApp: App {
    // App lifetime, independent of visible tabs or a dimmed/background scene.
    @StateObject private var receiver = LANAudioProbe()
    @StateObject private var remote = PhoneRemote()
    var body: some Scene {
        WindowGroup {
            WatchTestView(lanAudio: receiver, remote: remote)
        }
    }
}
