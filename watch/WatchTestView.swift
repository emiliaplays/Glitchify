import SwiftUI

@MainActor
struct WatchTestView: View {
    @StateObject private var audio = LocalAudioDiagnostic()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Glitchify")
                        .font(.title3.bold())
                    Text("Watch-Test")
                        .font(.headline)
                        .foregroundStyle(.cyan)
                }

                Text("Lokaler Audiotest. Spotify ist noch nicht angebunden.")
                    .font(.footnote)

                Button(action: audio.playTestTone) {
                    Label("Testton abspielen", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.cyan)
                .disabled(audio.isPresenting)

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
    }
}
