import Foundation

@main struct LANPCMBufferTests {
    static func main() {
        for host in ["10.0.0.2", "172.16.0.2", "172.31.255.254", "192.168.1.5"] {
            precondition(LANPCMBuffer.endpoint(host)?.path == "/glitchify-tone")
        }
        for host in ["", "127.0.0.1", "0.0.0.0", "8.8.8.8", "172.32.0.1", "192.168.1.255",
                     "192.168.1.0", "192.168.1.256", "192.168.01.2", "10.0.0.2@evil.test", "10.0.0.2/", "::1"] {
            precondition(LANPCMBuffer.endpoint(host) == nil)
        }
        let partial = LANPCMBuffer()
        precondition(partial.append(Data([1, 2, 3])))
        precondition(partial.take(maxBytes: 20) == Data([1, 2]))
        precondition(partial.append(Data([4])))
        precondition(partial.take(maxBytes: 20) == Data([3, 4]))
        partial.finish(error: nil)
        precondition(partial.snapshot().failure != nil)

        let overflow = LANPCMBuffer()
        precondition(!overflow.append(Data(count: LANPCMBuffer.capacity + 1)))
        precondition(overflow.snapshot().queued == 0)
        precondition(!overflow.append(Data([1, 2])))

        let complete = LANPCMBuffer()
        for _ in 0..<200 {
            precondition(complete.append(Data(count: 4800)))
            precondition(complete.take(maxBytes: 4800).count == 4800)
        }
        precondition(!complete.snapshot().finished)
        complete.finish(error: nil)
        precondition(complete.snapshot().failure == nil)
        precondition(complete.snapshot().finished)
        precondition(!complete.append(Data([1, 2])))

        let tooLong = LANPCMBuffer()
        for _ in 0..<200 {
            precondition(tooLong.append(Data(count: 4800)))
            _ = tooLong.take(maxBytes: 4800)
        }
        precondition(!tooLong.append(Data([1, 2])))
        print("PASS: LAN endpoint restrictions, fragmentation, overflow, finite completion, late/oversize data")
    }
}
