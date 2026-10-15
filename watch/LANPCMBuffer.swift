import Foundation

/// 24 kHz mono PCM16, either finite diagnostic or a paired live stream.
final class LANPCMBuffer {
    static let byteLimit = 960_000
    static let capacity = 65_536
    static let format = "pcm_s16le_24000_mono"
    private let lock = NSLock()
    private var bytes = Data()
    private var received = 0
    private var finished = false
    private var failure: String?
    private let continuous: Bool
    private var skipped = 0

    init(continuous: Bool = false) { self.continuous = continuous }

    static func endpoint(_ input: String) -> URL? {
        let host = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var octets: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
                  let number = Int(part), (0...255).contains(number), String(number) == part else { return nil }
            octets.append(number)
        }
        guard octets[0] == 10 || (octets[0] == 172 && (16...31).contains(octets[1]))
                || (octets[0] == 192 && octets[1] == 168),
              octets[3] != 0, octets[3] != 255 else { return nil }
        return URL(string: "http://\(host):8765/glitchify-tone")
    }

    func append(_ data: Data) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard failure == nil, !finished else { return false }
        guard data.count <= Int.max - received,
              continuous || (data.count <= Self.capacity - bytes.count && data.count <= Self.byteLimit - received) else {
            failure = "WLAN-Pufferlimit erreicht."
            bytes.removeAll(keepingCapacity: false)
            return false
        }
        if continuous, data.count > Self.capacity - bytes.count {
            // Drop whole old samples only, retaining at most half a second after a stall.
            // Avoid a second allocation proportional to an aggregated network callback.
            let drop = (bytes.count + data.count - 24_000 + 1) & ~1
            if drop >= bytes.count {
                let offset = drop - bytes.count
                bytes = Data(data.dropFirst(offset))
            } else {
                bytes.removeFirst(drop)
                bytes.append(data)
            }
            skipped += drop
            received += data.count
            return true
        }
        bytes.append(data)
        received += data.count
        return true
    }

    func finish(error: String?) {
        lock.lock(); defer { lock.unlock() }
        finished = true
        if failure == nil, let error { failure = error }
        if failure == nil, !continuous, received != Self.byteLimit { failure = "WLAN-Test unvollständig übertragen." }
        if failure == nil, continuous, received % 2 != 0 { failure = "Unvollständiges Audiosample." }
        if failure != nil { bytes.removeAll(keepingCapacity: false) }
    }

    func take(maxBytes: Int) -> Data {
        lock.lock(); defer { lock.unlock() }
        guard failure == nil else { return Data() }
        let count = min(max(0, maxBytes), bytes.count) & ~1
        let result = Data(bytes.prefix(count))
        bytes.removeFirst(count)
        return result
    }

    func snapshot() -> (received: Int, queued: Int, finished: Bool, failure: String?, skipped: Int) {
        lock.lock(); defer { lock.unlock() }
        return (received, bytes.count, finished, failure, skipped)
    }
}
