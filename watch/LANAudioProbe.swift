import AVFoundation
import Combine
import Foundation

private final class LANTransfer: NSObject, URLSessionDataDelegate {
    let buffer: LANPCMBuffer
    private var accepted = false // serial URLSession delegate queue only
    let pairing: PhoneRelayPairing?
    init(pairing: PhoneRelayPairing? = nil) {
        self.pairing = pairing
        self.buffer = LANPCMBuffer(continuous: pairing != nil)
        super.init()
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard let pairing else { completionHandler(.performDefaultHandling, nil); return }
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust, pairing.verify(trust) else {
            buffer.finish(error: "Die iPhone-Kopplung konnte nicht verifiziert werden.")
            completionHandler(.cancelAuthenticationChallenge, nil); return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              (pairing == nil ? http.expectedContentLength == Int64(LANPCMBuffer.byteLimit)
                : http.expectedContentLength == -1 && http.value(forHTTPHeaderField: "X-Glitchify-Mode") == "live"),
              http.value(forHTTPHeaderField: "X-Glitchify-Format") == LANPCMBuffer.format,
              http.mimeType == "application/octet-stream" else {
            buffer.finish(error: "Server liefert kein passendes Testaudio.")
            completionHandler(.cancel)
            return
        }
        accepted = true
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if !accepted || !buffer.append(data) { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let detail = (error as NSError?).map { "WLAN-Verbindung beendet (Code \($0.code))." }
        buffer.finish(error: detail)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        buffer.finish(error: "Der Testserver darf nicht weiterleiten.")
        completionHandler(nil)
    }
}

private final class LANAudioResources {
    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    init() { engine.attach(player) }
    deinit { player.stop(); engine.stop() }
}

/// Paired music survives scene changes; watchOS may still interrupt its route.
@MainActor
final class LANAudioProbe: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var status = "Bereit für den WLAN-Test."
    @Published private(set) var detail = "20 Sekunden Testaudio vom Computer im selben WLAN."
    @Published private(set) var route = "Audioausgang noch nicht geprüft."
    @Published private(set) var failed = false
    @Published private(set) var startedBeforeTransferFinished = false
    @Published private(set) var systemVolume = Double(AVAudioSession.sharedInstance().outputVolume)
    @Published private(set) var backgroundStatus = "Hintergrund-Audio noch nicht geprüft."
    private static var sessionOwner: UUID?
    private let audioSession = AVAudioSession.sharedInstance()
    private var audio = LANAudioResources()
    private var runID: UUID?
    private var activating = false
    private var cancelled = false
    private var poll: Task<Void, Never>?
    private var transfer: LANTransfer?
    private var connection: URLSession?
    private var request: URLSessionDataTask?
    private var format: AVAudioFormat?
    private var queued = 0
    private var observers: [NSObjectProtocol] = []
    private var lastReceived = 0
    private var lastArrival = Date()
    private var deadline = Date()
    private var started = false
    private var playedSamples = 0
    private var phonePairing: PhoneRelayPairing?
    private var volumeObserver: NSKeyValueObservation?
    private var reconfigureTask: Task<Void, Never>?
    private var renderGeneration = 0
    private var diagnosticRows: [[String: Any]] = []
    private var lastDiagnostic = Date.distantPast
    private var phase = "active"
    private var peak: Float = 0
    private var rms: Float = 0

    init() {
        volumeObserver = audioSession.observe(\.outputVolume, options: [.initial, .new]) { [weak self] session, _ in
            let volume = Double(session.outputVolume)
            Task { @MainActor [weak self] in self?.systemVolume = volume }
        }
    }

    func sceneChanged(_ phase: String) {
        self.phase = phase
        if runID != nil { record("scene_" + phase) }
        if phase == "background", phonePairing == nil { stop() }
    }

    /// Small local counters only: no audio, track metadata, IP or pairing token.
    private func record(_ event: String, code: Int? = nil) {
        let state = transfer?.buffer.snapshot()
        var row: [String: Any] = [
            "time": Date().timeIntervalSince1970, "event": event, "phase": phase,
            "policy": audioSession.routeSharingPolicy.rawValue,
            "outputs": audioSession.currentRoute.outputs.map { $0.portType.rawValue },
            "system_volume": audioSession.outputVolume, "player_gain": audio.player.volume,
            "engine_running": audio.engine.isRunning, "player_running": audio.player.isPlaying,
            "received": state?.received ?? lastReceived, "played_samples": playedSamples,
            "queued_buffers": queued, "peak": peak, "rms": rms
        ]
        if let code { row["code"] = code }
        diagnosticRows.append(row)
        if diagnosticRows.count > 64 { diagnosticRows.removeFirst(diagnosticRows.count - 64) }
        let report: [String: Any] = ["revision": "1.1-phone-relay-probe.4", "events": diagnosticRows,
                                    "status": status, "background_status": backgroundStatus]
        if let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first,
           let data = try? PropertyListSerialization.data(fromPropertyList: report, format: .binary, options: 0) {
            try? data.write(to: folder.appendingPathComponent("GlitchifyWatchAudio.plist"), options: .atomic)
        }
        lastDiagnostic = Date()
    }

    deinit {
        poll?.cancel()
        reconfigureTask?.cancel()
        request?.cancel()
        connection?.invalidateAndCancel()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        let abandonedID = runID
        Task { @MainActor in
            if let abandonedID, Self.sessionOwner == abandonedID {
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                Self.sessionOwner = nil
            }
        }
    }

    func start(host: String, phone: Bool = false, background: Bool = true) {
        guard runID == nil, Self.sessionOwner == nil else { return }
        guard var endpoint = LANPCMBuffer.endpoint(host) else {
            failed = true
            status = "Bitte die lokale IPv4-Adresse des Testservers eintragen."
            return
        }
        phonePairing = nil
        if phone {
            guard let pairing = PhoneRelayPairing.load(), let address = endpoint.host,
                  let secure = URL(string: "https://\(address):8766/glitchify-phone") else {
                failed = true; status = "Diese Testkopie hat noch keine lokale iPhone-Kopplung."; return
            }
            phonePairing = pairing; endpoint = secure
        }
        let id = UUID()
        runID = id
        Self.sessionOwner = id
        activating = true
        cancelled = false
        isRunning = true
        failed = false
        started = false
        startedBeforeTransferFinished = false
        queued = 0
        playedSamples = 0
        renderGeneration += 1
        diagnosticRows.removeAll()
        lastReceived = 0
        status = "Audioausgang wird vorbereitet …"
        detail = phone ? "WLAN-Musik vom iPhone" : "App während des Tests geöffnet lassen."
        audio = LANAudioResources()
        // System volume is controlled by WKInterfaceVolumeControl. Do not apply
        // another independent 35% attenuator or interpret it as hardware volume.
        audio.player.volume = phone ? 1 : 0.35
        do { try audioSession.setCategory(.playback, mode: .default, policy: .default, options: []) }
        catch {
            activating = false
            finish(id, "Audioausgang nicht verfügbar.", failed: true)
            return
        }
        audioSession.activate(options: []) { [weak self] active, error in
            let valid = active && error == nil
            Task { @MainActor [weak self] in
                guard let self else {
                    if Self.sessionOwner == id {
                        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                        Self.sessionOwner = nil
                    }
                    return
                }
                guard self.runID == id else { return }
                self.activating = false
                guard valid, !self.cancelled else {
                    self.finish(id, self.cancelled ? "WLAN-Test gestoppt." : "Audiofreigabe fehlgeschlagen.", failed: !self.cancelled)
                    return
                }
                // Keep the already activated output, then request long-form
                // execution for real music. This older-speaker compatibility
                // path is experimental until confirmed on Series 5 hardware.
                self.backgroundStatus = "Lautsprecher-Modus ohne Hintergrundfreigabe."
                if phone, background {
                    let original = self.audioSession.currentRoute.outputs.map { $0.portType }
                    do {
                        try self.audioSession.setCategory(.playback, mode: .default, policy: .longFormAudio, options: [])
                        guard !original.isEmpty,
                              self.audioSession.currentRoute.outputs.map({ $0.portType }) == original else {
                            throw NSError(domain: "GlitchifyAudioRoute", code: 1)
                        }
                        self.backgroundStatus = "Hintergrundmodus angefordert · Gerätetest erforderlich."
                        self.record("long_form_requested")
                    } catch {
                        self.record("long_form_unavailable", code: (error as NSError).code)
                        do { try self.audioSession.setCategory(.playback, mode: .default, policy: .default, options: []) }
                        catch { self.finish(id, "Lautsprecher konnte nicht wiederhergestellt werden.", failed: true); return }
                        self.backgroundStatus = "Hintergrundmodus auf diesem Ausgang nicht verfügbar."
                    }
                }
                self.connect(id, endpoint: endpoint)
            }
        }
    }

    private func connect(_ id: UUID, endpoint: URL) {
        let outputs = audioSession.currentRoute.outputs
        route = outputs.contains { $0.portType == .builtInSpeaker }
            ? "Eingebauter Watch-Lautsprecher" : "Anderer Audioausgang"
        guard !outputs.isEmpty,
              let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1) else {
            finish(id, "Kein Audioausgang verfügbar.", failed: true); return
        }
        self.format = format
        do {
            audio.engine.connect(audio.player, to: audio.engine.mainMixerNode, format: format)
            audio.engine.prepare()
            try audio.engine.start()
        } catch { finish(id, "Audio-Engine konnte nicht starten.", failed: true); return }
        for name in [AVAudioSession.routeChangeNotification, AVAudioSession.interruptionNotification,
                     AVAudioSession.mediaServicesWereResetNotification, AVAudioSession.mediaServicesWereLostNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: audioSession, queue: nil) { [weak self] notification in
                let reason = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?.uintValue ?? 0
                let interruption = (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue
                Task { @MainActor [weak self] in
                    guard let self, self.runID == id else { return }
                    if name == AVAudioSession.routeChangeNotification {
                        self.record("route_changed", code: Int(reason))
                        if WatchAudioPolicy.mustStop(routeReason: reason, hasOutput: !self.audioSession.currentRoute.outputs.isEmpty) {
                            self.finish(id, "Audioausgang getrennt. Bitte erneut verbinden.", failed: true)
                        } else { self.updateRoute() }
                    } else if name == AVAudioSession.interruptionNotification {
                        self.record("interruption", code: interruption.map(Int.init))
                        if interruption == AVAudioSession.InterruptionType.began.rawValue {
                            self.finish(id, "watchOS hat die Audio-Session unterbrochen.", failed: true)
                        }
                    } else {
                        self.record("media_services_lost_or_reset")
                        self.finish(id, "watchOS-Audiodienst neu gestartet. Bitte erneut verbinden.", failed: true)
                    }
                }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
            object: audio.engine, queue: nil) { [weak self] _ in
                Task { @MainActor [weak self] in self?.reconfigure(id) }
            })
        record("engine_started")
        let delegate = LANTransfer(pairing: phonePairing)
        transfer = delegate
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = phonePairing == nil ? 30 : 12 * 3600
        config.allowsCellularAccess = false
        config.waitsForConnectivity = false
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: delegateQueue)
        connection = session
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if let phonePairing { urlRequest.setValue("Bearer " + phonePairing.token, forHTTPHeaderField: "Authorization") }
        let task = session.dataTask(with: urlRequest)
        request = task
        lastArrival = Date()
        deadline = Date().addingTimeInterval(phonePairing == nil ? 30 : 12 * 3600)
        status = phonePairing == nil ? "Verbinde mit dem WLAN-Testserver …" : "Verbinde mit dem iPhone …"
        task.resume()
        poll = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 20_000_000) } catch { return }
                guard let self, self.runID == id else { return }
                self.drain(id)
            }
        }
    }

    private func updateRoute() {
        let outputs = audioSession.currentRoute.outputs
        route = outputs.contains { $0.portType == .builtInSpeaker }
            ? "Eingebauter Watch-Lautsprecher" : "Anderer Audioausgang"
    }

    private func reconfigure(_ id: UUID) {
        guard runID == id, reconfigureTask == nil else { return }
        reconfigureTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
            guard let self, self.runID == id, let format = self.format else { return }
            defer { self.reconfigureTask = nil }
            self.record("engine_configuration_changed")
            self.renderGeneration += 1
            self.audio.player.stop(); self.audio.engine.stop()
            self.queued = 0; self.started = false
            self.audio.engine.disconnectNodeOutput(self.audio.player)
            self.audio.engine.connect(self.audio.player, to: self.audio.engine.mainMixerNode, format: format)
            do { try self.audio.engine.start() }
            catch { self.finish(id, "Audioausgang konnte nicht neu gestartet werden.", failed: true) }
        }
    }

    private func drain(_ id: UUID) {
        guard runID == id, let transfer, let format else { return }
        let snapshot = transfer.buffer.snapshot()
        if let failure = snapshot.failure { record("network_or_format_failure"); finish(id, failure, failed: true); return }
        let now = Date()
        if snapshot.received != lastReceived { lastReceived = snapshot.received; lastArrival = now }
        if now > deadline || (!snapshot.finished && now.timeIntervalSince(lastArrival) > 8) {
            finish(id, "WLAN-Test wegen Zeitüberschreitung gestoppt.", failed: true); return
        }
        while queued < 4 {
            let state = transfer.buffer.snapshot()
            if state.queued < 4_800 && !state.finished { break }
            let data = transfer.buffer.take(maxBytes: 4_800)
            if data.isEmpty { break }
            let count = data.count / 2
            guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
                  let samples = pcm.floatChannelData?[0] else {
                finish(id, "Audiopuffer konnte nicht erstellt werden.", failed: true); return
            }
            pcm.frameLength = AVAudioFrameCount(count)
            var maximum: Float = 0
            var energy: Double = 0
            data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                for index in 0..<count {
                    let word = UInt16(raw[index * 2]) | UInt16(raw[index * 2 + 1]) << 8
                    let sample = Float(Int16(bitPattern: word)) / 32768
                    samples[index] = phonePairing == nil ? max(-0.2, min(0.2, sample)) : sample
                    maximum = max(maximum, abs(sample)); energy += Double(sample) * Double(sample)
                }
            }
            peak = maximum; rms = Float(sqrt(energy / Double(max(1, count))))
            queued += 1
            let render = renderGeneration
            audio.player.scheduleBuffer(pcm, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.runID == id, self.renderGeneration == render else { return }
                    self.queued = max(0, self.queued - 1)
                    self.playedSamples += count
                }
            }
        }
        if !started, queued >= 2 || (snapshot.finished && queued > 0) {
            started = true
            startedBeforeTransferFinished = !snapshot.finished
            audio.player.play()
            status = "WLAN-Audio läuft."
            record("playback_started")
        }
        detail = "Empfangen: \(snapshot.received / 1000) kB · Gespielt: \(playedSamples / 24_000) s\n"
            + (startedBeforeTransferFinished ? "Start während der Übertragung bestätigt." : "Warte auf Audio …")
        if snapshot.skipped > 0 { detail += "\nNach WLAN-Verzögerung neu synchronisiert." }
        if now.timeIntervalSince(lastDiagnostic) >= 5 { record("playing") }
        let final = transfer.buffer.snapshot()
        if final.finished, final.queued == 0, queued == 0 {
            let verified = startedBeforeTransferFinished && (phonePairing != nil ? playedSamples > 0 : playedSamples == 480_000)
            finish(id, verified ? "WLAN-Audio beendet." : "Fortlaufende Wiedergabe nicht bestätigt.", failed: !verified)
        }
    }

    func stop() {
        guard let id = runID else { return }
        cancelled = true
        if activating { status = "Stoppe nach Audiofreigabe …"; return }
        finish(id, "WLAN-Test gestoppt.", failed: false)
    }

    private func finish(_ id: UUID, _ text: String, failed: Bool) {
        guard runID == id else { return }
        status = text
        record("stopping", code: failed ? 1 : 0)
        runID = nil
        reconfigureTask?.cancel(); reconfigureTask = nil
        renderGeneration += 1
        poll?.cancel(); poll = nil
        request?.cancel(); request = nil
        connection?.invalidateAndCancel(); connection = nil
        transfer = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        audio.player.stop()
        audio.engine.stop()
        queued = 0
        format = nil
        isRunning = false
        self.failed = failed
        status = text
        if Self.sessionOwner == id {
            Self.sessionOwner = nil
            do { try audioSession.setActive(false, options: .notifyOthersOnDeactivation) }
            catch { self.failed = true; detail += " Audiofreigabe nicht beendet." }
        }
    }
}
