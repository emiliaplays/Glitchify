import SwiftUI

@MainActor
struct WatchTestView: View {
    @StateObject private var audio = LocalAudioDiagnostic()
    @StateObject private var streamAudio = ForegroundAudioProbe()
    @StateObject private var lanAudio = LANAudioProbe()
    @AppStorage("GlitchifyLANTestHost") private var serverHost =
        Bundle.main.object(forInfoDictionaryKey: "GlitchifyLANTestHost") as? String ?? ""
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Glitchify")
                        .font(.title3.bold())
                    Text("WLAN-Audio: Empfangstest")
                        .font(.headline)
                        .foregroundStyle(.cyan)
                }

                Text("20 Sekunden Testaudio über WLAN. Spotify vom iPhone folgt im nächsten Schritt.")
                    .font(.footnote)

                TextField("Testserver: IPv4-Adresse", text: $serverHost)
                    .disabled(lanAudio.isRunning)
                Button {
                    lanAudio.start(host: serverHost)
                } label: {
                    Label("WLAN-Ton testen", systemImage: "wifi")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.cyan)
                .disabled(lanAudio.isRunning || streamAudio.isRunning || audio.isPresenting)
                if lanAudio.isRunning {
                    Button("WLAN-Test stoppen", role: .cancel, action: lanAudio.stop)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(lanAudio.status).foregroundStyle(lanAudio.failed ? Color.orange : Color.primary)
                    Text(lanAudio.route)
                    Text(lanAudio.detail).foregroundStyle(.secondary)
                }
                .font(.caption2)
                .accessibilityElement(children: .combine)
                Text("Testserver und Watch müssen im selben WLAN sein. App offen lassen; der Test endet nach 20 Sekunden.")
                    .font(.caption2).foregroundStyle(.secondary)
                Divider()
                Text("Lokaler Audiotest").font(.headline)

                Button(action: streamAudio.start) {
                    Label("Audioausgabe testen", systemImage: "waveform")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.cyan)
                .disabled(streamAudio.isRunning || audio.isPresenting || lanAudio.isRunning)

                if streamAudio.isRunning {
                    Button("Test stoppen", role: .cancel, action: streamAudio.stop)
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text(streamAudio.status)
                        .foregroundStyle(streamAudio.hasError ? Color.orange : Color.primary)
                    Text(streamAudio.routeDescription)
                    Text(streamAudio.detail)
                        .foregroundStyle(.secondary)
                }
                .font(.caption2)
                .accessibilityElement(children: .combine)

                Text("App offen lassen und Bluetooth-Kopfhörer trennen. Der Test endet automatisch nach 10 Sekunden.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Divider()
                Text("Bisheriger Dateitest")
                    .font(.headline)

                Button(action: audio.playTestTone) {
                    Label("Testton abspielen", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.cyan)
                .disabled(audio.isPresenting || streamAudio.isRunning || lanAudio.isRunning)

                Text("Für den Lautsprechertest Bluetooth-Kopfhörer trennen. watchOS wählt den Ausgang.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Divider()

                VStack(alignment: .leading, spacing: 5) {
                    Label(audio.status, systemImage: audio.hasError ? "exclamationmark.circle" : "info.circle")
                        .font(.footnote)
                        .foregroundStyle(audio.hasError ? Color.orange : Color.primary)
                    Text(audio.detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)

                Text(audio.deviceDescription)
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Text("Ob der Ton hörbar war, prüfst du selbst. Der Test erkennt den Audioausgang nicht.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            .padding(.vertical, 8)
        }
        .onChange(of: scenePhase) { phase in
            if phase == .background {
                streamAudio.stopForBackground()
                lanAudio.stop()
            }
        }
        .onDisappear { streamAudio.stopForBackground(); lanAudio.stop() }
    }
}
