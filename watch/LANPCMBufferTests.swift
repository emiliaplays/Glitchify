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
        let live = LANPCMBuffer(continuous: true)
        for _ in 0..<1200 {
            precondition(live.append(Data(count: 4800)))
            precondition(live.take(maxBytes: 4800).count == 4800)
        }
        precondition(live.snapshot().received > LANPCMBuffer.byteLimit)
        live.finish(error: nil)
        precondition(live.snapshot().failure == nil)
        precondition(!live.append(Data([1, 2])))

        // Odd network fragments must preserve sample alignment after a backlog trim.
        let late = LANPCMBuffer(continuous: true)
        let pattern = Data((0..<100_000).map { UInt8($0 % 251) })
        precondition(late.append(Data(pattern.prefix(3))))
        precondition(late.append(Data(pattern.dropFirst(3))))
        let lateState = late.snapshot()
        precondition(lateState.queued == 24_000 && lateState.skipped == 76_000)
        precondition(late.take(maxBytes: 100_000) == Data(pattern.suffix(24_000)))
        late.finish(error: nil)
        precondition(late.snapshot().failure == nil)
        let broken = LANPCMBuffer(continuous: true)
        precondition(broken.append(Data([1])))
        broken.finish(error: nil)
        precondition(broken.snapshot().failure != nil)
        let errored = LANPCMBuffer(continuous: true)
        errored.finish(error: "TLS identity rejected")
        errored.finish(error: "Cancelled")
        precondition(errored.snapshot().failure == "TLS identity rejected")
        print("PASS: LAN endpoint restrictions, fragmentation, overflow, finite completion, late/oversize data")
        print("PASS: two-minute live stream, bounded resynchronization, sample alignment and first error")
    }
}
