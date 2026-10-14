import SwiftUI

@MainActor
struct WatchTestView: View {
    @StateObject private var audio = LocalAudioDiagnostic()
    @StateObject private var streamAudio = ForegroundAudioProbe()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Glitchify")
                        .font(.title3.bold())
                    Text("WLAN-Audio: Vorabtest")
                        .font(.headline)
                        .foregroundStyle(.cyan)
                }

                Text("Prüft den Lautsprecher für fortlaufendes Audio. Noch keine Übertragung vom iPhone.")
                    .font(.footnote)

                Button(action: streamAudio.start) {
                    Label("Audioausgabe testen", systemImage: "waveform")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.cyan)
                .disabled(streamAudio.isRunning || audio.isPresenting)

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
                .disabled(audio.isPresenting || streamAudio.isRunning)

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
            if phase == .background { streamAudio.stopForBackground() }
        }
        .onDisappear { streamAudio.stopForBackground() }
    }
}
