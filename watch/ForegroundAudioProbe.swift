import AVFoundation
import Combine
import Foundation

/// Owns the engine independently of callbacks, so releasing the view also stops it.
private final class ForegroundProbeAudio {
    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()

    init() {
        engine.attach(player)
    }

    deinit {
        player.stop()
        engine.stop()
    }
}

/// A foreground capability test, not a file player or a Spotify receiver.
@MainActor
final class ForegroundAudioProbe: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var status = "Bereit für den direkten Audiotest."
    @Published private(set) var detail = "10 Sekunden leiser Testton, erst nach deinem Tippen."
    @Published private(set) var hasError = false
    @Published private(set) var routeDescription = "Audioausgang noch nicht geprüft."
    @Published private(set) var isBuiltInSpeaker = false

    private static var sessionOwner: UUID?
    private static let sampleRate = 24_000.0
    private static let framesPerBuffer = 6_000
    private static let totalFrames = 240_000
    private static let maximumPendingBuffers = 4

    private var audio = ForegroundProbeAudio()
    private let session = AVAudioSession.sharedInstance()
    private var observers: [NSObjectProtocol] = []
    private var runID: UUID?
    private var activating = false
    private var stopRequested = false
    private var nextFrame = 0
    private var pendingBuffers = 0
    private var rebuildAudioOnNextStart = false
    private var audioFormat: AVAudioFormat?
    private var deadline: Task<Void, Never>?

    deinit {
        deadline?.cancel()
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        let abandonedID = runID
        Task { @MainActor in
            if let abandonedID, Self.sessionOwner == abandonedID {
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                Self.sessionOwner = nil
            }
        }
    }

    func start() {
        guard runID == nil, Self.sessionOwner == nil else { return }
        if rebuildAudioOnNextStart {
            audio = ForegroundProbeAudio()
            rebuildAudioOnNextStart = false
        }
        let id = UUID()
        runID = id
        Self.sessionOwner = id
        activating = true
        stopRequested = false
        nextFrame = 0
        pendingBuffers = 0
        isRunning = true
        hasError = false
        isBuiltInSpeaker = false
        status = "Audioausgang wird vorbereitet …"
        detail = "Der Test verwendet weder Mikrofon noch Netzwerk."
        routeDescription = "Audioausgang wird geprüft …"

        do {
            // Set the category BEFORE activation. No long-form policy or route override.
            try session.setCategory(.playback, mode: .default, policy: .default, options: [])
        } catch {
            activating = false
            finish(id, status: "Audiotest nicht möglich.", detail: errorDetail(error), failed: true)
            return
        }
        observe(AVAudioSession.interruptionNotification, id: id)
        observe(AVAudioSession.mediaServicesWereResetNotification, id: id)

        // Apple's async activation also supports the default policy; the route picker
        // is associated with playback + longForm, which this probe does not request.
        session.activate(options: []) { [weak self] activated, error in
            let code = (error as NSError?).map { $0.code }
            Task { @MainActor [weak self] in
                guard let self else {
                    if Self.sessionOwner == id || Self.sessionOwner == nil {
                        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                        Self.sessionOwner = nil
                    }
                    return
                }
                self.activationCompleted(id, activated: activated, errorCode: code)
            }
        }
    }

    func stop() {
        requestStop(status: "Audiotest gestoppt.")
    }

    /// The view must call this when its scene leaves the active state.
    func stopForBackground() {
        requestStop(status: "Audiotest beim Verlassen der App gestoppt.")
    }

    private func activationCompleted(_ id: UUID, activated: Bool, errorCode: Int?) {
        guard runID == id, Self.sessionOwner == id else { return }
        activating = false
        if stopRequested {
            finish(id, status: status, detail: "Kein Ton läuft weiter.", failed: false)
            return
        }
        guard activated, errorCode == nil else {
            let reason = errorCode.map { "Audiofreigabe fehlgeschlagen (Code \($0))." }
                ?? "watchOS hat den Audioausgang nicht freigegeben."
            finish(id, status: "Audiotest nicht möglich.", detail: reason, failed: true)
            return
        }
        updateRoute()
        guard !session.currentRoute.outputs.isEmpty,
              let format = AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 1) else {
            finish(id, status: "Kein Audioausgang verfügbar.", detail: "watchOS meldet keinen verwendbaren Ausgang.", failed: true)
            return
        }
        audioFormat = format
        // Observe subsequent changes only. Initial route selection may itself post
        // a route notification before activation has completed.
        observe(AVAudioSession.routeChangeNotification, id: id)

        do {
            audio.player.stop()
            audio.engine.stop()
            audio.engine.disconnectNodeOutput(audio.player)
            audio.engine.connect(audio.player, to: audio.engine.mainMixerNode, format: format)
            audio.engine.prepare()
            try audio.engine.start()
        } catch {
            finish(id, status: "Audiotest nicht möglich.", detail: errorDetail(error), failed: true)
            return
        }
        status = "Direkter Audiotest läuft."
        detail = "10 Sekunden · Ob du den Ton hörst, prüfst du selbst."
        fillQueue(id)
        guard runID == id else { return }
        audio.player.play()

        // A stalled completion must never leave a tone playing indefinitely.
        deadline = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 12_000_000_000) } catch { return }
            guard let self, self.runID == id else { return }
            self.finish(id, status: "Audiotest nach Zeitlimit beendet.",
                        detail: "Die Wiedergabe hat ihr Ende nicht rechtzeitig bestätigt.", failed: true)
        }
    }

    private func fillQueue(_ id: UUID) {
        guard runID == id, !stopRequested, let format = audioFormat else { return }
        while pendingBuffers < Self.maximumPendingBuffers, nextFrame < Self.totalFrames {
            let count = min(Self.framesPerBuffer, Self.totalFrames - nextFrame)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
                  let samples = buffer.floatChannelData?[0] else {
                finish(id, status: "Audiotest nicht möglich.", detail: "Der kleine Audiopuffer konnte nicht erstellt werden.", failed: true)
                return
            }
            buffer.frameLength = AVAudioFrameCount(count)
            for index in 0..<count {
                let frame = nextFrame + index
                let fadeFrames = Self.sampleRate * 0.05
                let fadeIn = min(1.0, Double(frame) / fadeFrames)
                let fadeOut = min(1.0, Double(Self.totalFrames - 1 - frame) / fadeFrames)
                let phase = 2.0 * Double.pi * 440.0 * Double(frame) / Self.sampleRate
                samples[index] = Float(0.03 * fadeIn * fadeOut * sin(phase))
            }
            nextFrame += count
            pendingBuffers += 1
            // Refill only after a buffer has actually played. Four buffers maximum
            // means <= 1 second / 96 KB of our PCM data queued at a time.
            audio.player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.bufferPlayed(id)
                }
            }
        }
    }

    private func bufferPlayed(_ id: UUID) {
        guard runID == id, !stopRequested, !activating else { return }
        pendingBuffers = max(0, pendingBuffers - 1)
        if nextFrame == Self.totalFrames, pendingBuffers == 0 {
            updateRoute()
            finish(id, status: "Direkter Audiotest beendet.",
                   detail: "10 Sekunden an den Audioausgang übergeben. Hörbarkeit bitte selbst prüfen.", failed: false)
        } else {
            fillQueue(id)
        }
    }

    private func requestStop(status newStatus: String) {
        guard let id = runID else { return }
        if activating {
            // An in-flight activation cannot be cancelled. Keep Start locked until
            // its callback arrives, then deactivate without ever starting the engine.
            stopRequested = true
            status = newStatus
            detail = "Die laufende Audiofreigabe wird noch abgeschlossen."
            return
        }
        finish(id, status: newStatus, detail: "Kein Ton läuft weiter.", failed: false)
    }

    private func observe(_ name: Notification.Name, id: UUID) {
        let token = NotificationCenter.default.addObserver(forName: name, object: session, queue: nil) { [weak self] _ in
            // Transfer fixed, value-only diagnostics; a queued event from a previous
            // run cannot stop the next run.
            Task { @MainActor [weak self] in
                self?.audioEnvironmentChanged(name, id: id)
            }
        }
        observers.append(token)
    }

    private func audioEnvironmentChanged(_ name: Notification.Name, id: UUID) {
        guard runID == id else { return }
        if name == AVAudioSession.mediaServicesWereResetNotification {
            rebuildAudioOnNextStart = true
        }
        if name == AVAudioSession.routeChangeNotification {
            updateRoute()
            // Initial route selection is part of activation, not a mid-play change.
            guard !activating else { return }
            requestStop(status: "Audiotest wegen geändertem Audioausgang gestoppt.")
        } else {
            requestStop(status: "Audiotest durch watchOS unterbrochen.")
        }
    }

    private func updateRoute() {
        let outputs = session.currentRoute.outputs
        isBuiltInSpeaker = outputs.contains { $0.portType == .builtInSpeaker }
        let labels = outputs.map { output -> String in
            switch output.portType {
            case .builtInSpeaker: return "Eingebauter Watch-Lautsprecher"
            case .bluetoothA2DP, .bluetoothHFP, .bluetoothLE: return "Bluetooth-Audio"
            case .headphones: return "Kopfhörer"
            default: return "Anderer Audioausgang"
            }
        }
        routeDescription = labels.isEmpty ? "Kein Audioausgang gemeldet." : labels.joined(separator: " + ")
    }

    private func finish(_ id: UUID, status newStatus: String, detail newDetail: String, failed: Bool) {
        guard runID == id else { return }
        // Invalidate callbacks before stopping the node (stop may invoke callbacks).
        runID = nil
        activating = false
        stopRequested = true
        deadline?.cancel()
        deadline = nil
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
        audio.player.stop()
        audio.engine.stop()
        audioFormat = nil
        pendingBuffers = 0
        isRunning = false
        status = newStatus
        detail = newDetail
        hasError = failed
        if Self.sessionOwner == id {
            Self.sessionOwner = nil
            do {
                try session.setActive(false, options: .notifyOthersOnDeactivation)
            } catch {
                hasError = true
                detail += " Audiofreigabe konnte nicht beendet werden (Code \((error as NSError).code))."
            }
        }
    }

    private func errorDetail(_ error: Error) -> String {
        // Fixed text plus numeric code; no device names, URLs, or system log dumps.
        "watchOS meldet einen Audiofehler (Code \((error as NSError).code))."
    }
}
