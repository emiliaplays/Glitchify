import SwiftUI

@MainActor
struct WatchTestView: View {
    @ObservedObject var lanAudio: LANAudioProbe
    @ObservedObject var remote: PhoneRemote
    @StateObject private var audio = LocalAudioDiagnostic()
    @StateObject private var streamAudio = ForegroundAudioProbe()
    @AppStorage("GlitchifyPhoneRelayHost") private var phoneHost =
        Bundle.main.object(forInfoDictionaryKey: "GlitchifyPhoneRelayHost") as? String ?? ""
    @AppStorage("GlitchifyLANTestHost") private var serverHost = ""
    @AppStorage("GlitchifyWatchVolume") private var volume = 0.35
    @State private var page = 0
    @State private var showDiagnostics = false
    @Environment(\.scenePhase) private var scenePhase
    private let accent = Color(red: 0.78, green: 0.62, blue: 1)

    var body: some View {
        TabView(selection: $page) {
            player.tag(0)
            connection.tag(1)
        }
        .tabViewStyle(.page(indexDisplayMode: .automatic))
        .onAppear { lanAudio.setVolume(volume) }
        .onChange(of: volume) { lanAudio.setVolume($0) }
        .onChange(of: lanAudio.isRunning) { running in
            if !running { remote.stop() }
        }
        .onChange(of: scenePhase) { phase in
            remote.foreground = phase == .active
            if phase == .background {
                streamAudio.stopForBackground()
                lanAudio.sceneBackgrounded()
            }
        }
        // The app owns receiver/remote. Leaving a page does not stop real music.
    }

    private var player: some View {
        GeometryReader { size in
            VStack(spacing: 5) {
                HStack(spacing: 4) {
                    Circle().fill(lanAudio.isRunning ? Color.green : Color.gray).frame(width: 5, height: 5)
                    Text("GLITCHIFY").font(.system(size: 10, weight: .bold, design: .rounded)).tracking(1.5)
                    Spacer()
                    Button { page = 1 } label: { Image(systemName: "wifi").font(.caption2) }
                        .buttonStyle(.plain).accessibilityLabel("WLAN-Verbindung")
                }.foregroundStyle(accent)
                ZStack {
                    Circle().fill(LinearGradient(colors: [accent.opacity(0.7), .indigo.opacity(0.3)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    Circle().stroke(.white.opacity(0.2), lineWidth: 1).padding(6)
                    Image(systemName: "waveform").font(.system(size: 23, weight: .medium)).foregroundStyle(.white)
                }.frame(height: max(30, min(54, size.size.height * 0.22)))
                    .accessibilityHidden(true)
                Text(remote.title).font(.system(size: 14, weight: .semibold)).lineLimit(2).minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity)
                Text(remote.artist).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                ProgressView(value: remote.progress).tint(accent).accessibilityLabel("Titel-Fortschritt")
                if lanAudio.isRunning {
                    HStack(spacing: 10) {
                        transport("backward.end.fill", label: "Vorheriger Titel", action: "previous")
                        transport(remote.playing ? "pause.fill" : "play.fill", label: remote.playing ? "Am iPhone pausieren" : "Am iPhone abspielen", action: remote.playing ? "pause" : "play", prominent: true)
                        transport("forward.end.fill", label: "Nächster Titel", action: "next")
                    }.disabled(!remote.available || remote.busy)
                } else {
                    Button(action: connect) {
                        Label("Musik empfangen", systemImage: "play.fill").font(.system(size: 12, weight: .semibold))
                    }.buttonStyle(.borderedProminent).tint(accent).foregroundStyle(.black)
                        .disabled(streamAudio.isRunning || audio.isPresenting)
                }
                HStack(spacing: 4) {
                    Image(systemName: volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    Text("\(Int((volume * 100).rounded())) %").monospacedDigit()
                    Text("· Crown").foregroundStyle(.secondary)
                }.font(.system(size: 10)).foregroundStyle(accent)
                    .accessibilityLabel("Watch-Lautstärke \(Int((volume * 100).rounded())) Prozent. Mit Digital Crown ändern.")
            }
            .padding(.horizontal, 6)
            .frame(width: size.size.width, height: size.size.height, alignment: .center)
            .focusable()
            .digitalCrownRotation($volume, from: 0, through: 1, by: 0.05, sensitivity: .low, isContinuous: false, isHapticFeedbackEnabled: true)
        }
    }

    private func transport(_ symbol: String, label: String, action: String, prominent: Bool = false) -> some View {
        Button { remote.send(action) } label: {
            Image(systemName: symbol)
                .font(.system(size: prominent ? 21 : 17, weight: .semibold))
                .frame(width: prominent ? 48 : 40, height: 42)
                .background(prominent ? accent : Color.white.opacity(0.09), in: Capsule())
                .foregroundStyle(prominent ? Color.black : Color.white)
        }.buttonStyle(.plain).accessibilityLabel(label)
    }

    private var connection: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Verbindung").font(.title3.bold())
                TextField("iPhone: IPv4-Adresse", text: $phoneHost).disabled(lanAudio.isRunning)
                if lanAudio.isRunning {
                    Button("Empfang stoppen", role: .destructive) { lanAudio.stop(); remote.stop() }
                } else {
                    Button("Verbinden", action: connect).tint(accent)
                        .disabled(streamAudio.isRunning || audio.isPresenting)
                }
                Text(lanAudio.status).foregroundStyle(lanAudio.failed ? Color.orange : Color.primary)
                Text(lanAudio.route).foregroundStyle(.secondary)
                if !remote.message.isEmpty { Text(remote.message).foregroundStyle(.orange) }
                Text("iPhone und Watch im selben WLAN. Das iPhone bleibt die Musikquelle. Nur ein Audioempfänger gleichzeitig.").foregroundStyle(.secondary)
                Text("Hintergrund & Display aus: in dieser Testversion aktiviert; Series-5-Test noch ausstehend.").foregroundStyle(.secondary)
                Button {
                    showDiagnostics.toggle()
                } label: {
                    Label("Diagnose", systemImage: showDiagnostics ? "chevron.up" : "chevron.down")
                }
                if showDiagnostics {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(lanAudio.detail)
                        TextField("Testserver: IPv4", text: $serverHost)
                        Button("WLAN-Ton testen") { lanAudio.start(host: serverHost) }
                            .disabled(lanAudio.isRunning || streamAudio.isRunning || audio.isPresenting)
                        Button("Audioausgabe testen", action: streamAudio.start)
                            .disabled(lanAudio.isRunning || streamAudio.isRunning || audio.isPresenting)
                        if streamAudio.isRunning { Button("Test stoppen", action: streamAudio.stop) }
                        Text(streamAudio.status)
                        Text(streamAudio.routeDescription)
                        Button("Lokaler Testton", action: audio.playTestTone)
                            .disabled(lanAudio.isRunning || streamAudio.isRunning || audio.isPresenting)
                        Text(audio.status)
                    }
                }
            }.font(.caption2).padding(.horizontal, 4).padding(.bottom, 18)
        }
    }

    private func connect() {
        phoneHost = phoneHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard LANPCMBuffer.endpoint(phoneHost) != nil else { page = 1; return }
        lanAudio.setVolume(volume)
        lanAudio.start(host: phoneHost, phone: true)
        if lanAudio.isRunning { remote.start(host: phoneHost); page = 0 }
    }
}
