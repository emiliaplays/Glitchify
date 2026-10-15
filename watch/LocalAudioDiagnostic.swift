import Combine
import Foundation
import WatchKit

private struct PlaybackResult: Sendable {
    let didPlayToEnd: Bool
    let endTime: TimeInterval
    let errorMessage: String?
    let errorCode: String?
}

/// Presents only the bundled test clip. WatchKit owns playback and audio routing.
@MainActor
final class LocalAudioDiagnostic: ObservableObject {
    @Published private(set) var isPresenting = false
    @Published private(set) var status = "Bereit für den Audiotest."
    @Published private(set) var detail = "Der Ton startet erst nach deinem Tippen."
    @Published private(set) var hasError = false

    let deviceDescription: String

    init() {
        let device = WKInterfaceDevice.current()
        // Apple's model property is generic; it does not identify the Watch series.
        deviceDescription = "\(device.model) · watchOS \(device.systemVersion)"
    }

    func playTestTone() {
        guard !isPresenting else { return }
        guard let url = Bundle.main.url(forResource: "speaker-check", withExtension: "wav") else {
            status = "Testdatei fehlt."
            detail = "Diese Version enthält keinen Testton."
            hasError = true
            return
        }
        let application = WKApplication.shared()
        guard let controller = application.visibleInterfaceController ?? application.rootInterfaceController else {
            status = "Player noch nicht bereit."
            detail = "Öffne die App erneut und versuche es noch einmal."
            hasError = true
            return
        }

        isPresenting = true
        hasError = false
        status = "Audiotest geöffnet."
        detail = "Das Ergebnis erscheint nach dem Schließen des Players."

        // Autoplay applies only to this explicit button action, never app launch.
        // WatchKit selects Bluetooth when available, otherwise the Watch speaker.
        let options: [AnyHashable: Any] = [
            WKMediaPlayerControllerOptionsAutoplayKey: NSNumber(value: true),
            WKMediaPlayerControllerOptionsLoopsKey: NSNumber(value: false)
        ]
        controller.presentMediaPlayerController(with: url, options: options) { [weak self] didPlayToEnd, endTime, error in
            // Do not assume WatchKit's completion arrives on the main actor.
            // Transfer value-only diagnostics, not the Error object, into the task.
            let nsError = error as NSError?
            let result = PlaybackResult(
                didPlayToEnd: didPlayToEnd,
                endTime: endTime,
                errorMessage: nsError.map { String($0.localizedDescription.prefix(160)) },
                errorCode: nsError.map { "\(String($0.domain.prefix(60))) · \($0.code)" }
            )
            Task { @MainActor [weak self] in
                self?.complete(result)
            }
        }
    }

    private func complete(_ result: PlaybackResult) {
        isPresenting = false
        if let message = result.errorMessage {
            hasError = true
            status = "Wiedergabe nicht möglich."
            detail = [message, result.errorCode].compactMap { $0 }.joined(separator: "\n")
            return
        }

        hasError = false
        status = result.didPlayToEnd ? "Testton vollständig abgespielt." : "Audiotest beendet."
        let position = result.endTime.isFinite
            ? String(format: "%.1f s", locale: Locale(identifier: "de_DE"), max(0, result.endTime))
            : "Zeit nicht verfügbar"
        detail = "\(position) · \(result.didPlayToEnd ? "Dateiende erreicht" : "Vorzeitig beendet")"
        // Successful completion cannot establish which output was audible.
    }
}
