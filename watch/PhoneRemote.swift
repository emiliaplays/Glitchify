import Combine
import Foundation
import MediaPlayer

private final class ControlTrust: NSObject, URLSessionTaskDelegate {
    let pairing: PhoneRelayPairing
    init(_ pairing: PhoneRelayPairing) { self.pairing = pairing }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust, pairing.verify(trust) else {
            completionHandler(.cancelAuthenticationChallenge, nil); return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

private struct RemoteTrack: Decodable {
    let title: String, artist: String
    let playing: Bool, controls: Bool
    let duration: Double, elapsed: Double
}

/// Uses the same local pairing as audio. Commands are never retried automatically.
@MainActor
final class PhoneRemote: ObservableObject {
    @Published private(set) var title = "Musik vom iPhone"
    @Published private(set) var artist = "Glitchify"
    @Published private(set) var playing = false
    @Published private(set) var available = false
    @Published private(set) var busy = false
    @Published private(set) var message = ""
    @Published private(set) var progress = 0.0
    private var polling: Task<Void, Never>?
    private var commandTask: Task<Void, Never>?
    private var host = ""
    private var generation = UUID()
    var foreground = true

    func start(host: String) {
        stop(); self.host = host
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: "Glitchify · Musik vom iPhone",
            MPNowPlayingInfoPropertyPlaybackRate: 1.0
        ]
        let run = generation
        polling = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.generation == run else { return }
                if !self.busy { await self.refresh(run) }
                do { try await Task.sleep(nanoseconds: self.foreground ? 2_000_000_000 : 8_000_000_000) }
                catch { return }
            }
        }
    }
    func stop() {
        generation = UUID(); polling?.cancel(); polling = nil
        commandTask?.cancel(); commandTask = nil; available = false; busy = false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
    private func request(_ action: String) async throws -> Data {
        guard ["status", "play", "pause", "next", "previous"].contains(action),
              LANPCMBuffer.endpoint(host) != nil, let pairing = PhoneRelayPairing.load(),
              let url = URL(string: "https://\(host):8767/\(action)") else { throw URLError(.badURL) }
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 4; config.timeoutIntervalForResource = 6
        config.allowsCellularAccess = false; config.waitsForConnectivity = false
        let trust = ControlTrust(pairing)
        let session = URLSession(configuration: config, delegate: trust, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.httpMethod = action == "status" ? "GET" : "POST"
        if action != "status" { request.setValue("0", forHTTPHeaderField: "Content-Length") }
        request.setValue("Bearer " + pairing.token, forHTTPHeaderField: "Authorization")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, [200, 202].contains(http.statusCode),
              http.mimeType == "application/json", (0...8192).contains(http.expectedContentLength) else {
            throw URLError(.badServerResponse)
        }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 8192 else { throw URLError(.dataLengthExceedsMaximum) }
            data.append(byte)
        }
        return data
    }
    private func refresh(_ run: UUID) async {
        do {
            let data = try await request("status")
            let track = try JSONDecoder().decode(RemoteTrack.self, from: data)
            guard generation == run else { return }
            title = track.title.isEmpty ? "Musik vom iPhone" : track.title
            artist = track.artist.isEmpty ? "Glitchify" : track.artist
            playing = track.playing; available = track.controls
            progress = track.duration > 0 ? min(1, max(0, track.elapsed / track.duration)) : 0
            message = ""
            MPNowPlayingInfoCenter.default().nowPlayingInfo = [
                MPMediaItemPropertyTitle: title, MPMediaItemPropertyArtist: artist,
                MPMediaItemPropertyPlaybackDuration: track.duration,
                MPNowPlayingInfoPropertyElapsedPlaybackTime: track.elapsed,
                MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0
            ]
        } catch {
            guard generation == run, !Task.isCancelled else { return }
            available = false; message = "Steuerung nicht erreichbar. Glitchify am iPhone öffnen."
        }
    }
    func send(_ action: String) {
        guard available, !busy, ["play", "pause", "next", "previous"].contains(action) else { return }
        busy = true; let run = generation
        commandTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == run { self.busy = false } }
            do {
                _ = try await self.request(action)
                guard self.generation == run else { return }
                self.message = "Befehl gesendet"
                await self.refresh(run)
            } catch {
                guard self.generation == run, !Task.isCancelled else { return }
                self.message = "Befehl nicht bestätigt. Bitte erneut tippen."
            }
        }
    }
}
