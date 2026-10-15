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
    private var gain: Float = 0.35
    func setVolume(_ value: Double) {
        gain = Float(min(1, max(0, value)))
        audio.player.volume = gain
    }
    func sceneBackgrounded() {
        if phonePairing == nil { stop() }
    }

    deinit {
        poll?.cancel()
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

    func start(host: String, phone: Bool = false) {
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
        lastReceived = 0
        status = "Audioausgang wird vorbereitet …"
        detail = phone ? "WLAN-Musik vom iPhone" : "App während des Tests geöffnet lassen."
        audio = LANAudioResources()
        audio.player.volume = gain
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
                     AVAudioSession.mediaServicesWereResetNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: audioSession, queue: nil) { [weak self] _ in
                Task { @MainActor [weak self] in self?.finish(id, "WLAN-Test durch Audio-Wechsel unterbrochen.", failed: true) }
            })
        }
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

    private func drain(_ id: UUID) {
        guard runID == id, let transfer, let format else { return }
        let snapshot = transfer.buffer.snapshot()
        if let failure = snapshot.failure { finish(id, failure, failed: true); return }
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
            data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                for index in 0..<count {
                    let word = UInt16(raw[index * 2]) | UInt16(raw[index * 2 + 1]) << 8
                    let sample = Float(Int16(bitPattern: word)) / 32768
                    samples[index] = phonePairing == nil ? max(-0.2, min(0.2, sample)) : sample
                }
            }
            queued += 1
            audio.player.scheduleBuffer(pcm, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.runID == id else { return }
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
        }
        detail = "Empfangen: \(snapshot.received / 1000) kB · Gespielt: \(playedSamples / 24_000) s\n"
            + (startedBeforeTransferFinished ? "Start während der Übertragung bestätigt." : "Warte auf Audio …")
        if snapshot.skipped > 0 { detail += "\nNach WLAN-Verzögerung neu synchronisiert." }
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
        runID = nil
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
