import Darwin
import Foundation

/// Download and upload speed through the engine, from the byte counters of its tun interface. Everything the
/// engine carries goes through the tun (direct lists and all), so this is the Mac's traffic while it is connected.
/// No service call: the counters are public (getifaddrs), and the app reads them once a second while the window is open
/// (on any page, so the chart is whole when you come back to Home).
@MainActor
final class TrafficMonitor: ObservableObject {
    struct Sample: Identifiable, Equatable {
        let time: Date
        let down: Double // bytes per second
        let up: Double
        var id: Date { time }
    }

    /// The engine's tun address (core/build.go); the same coupling as `ksTunNet` in the daemon's kill switch.
    static let tunAddress = "172.19.0.1"
    static let window = 60 // seconds the chart shows

    @Published private(set) var samples: [Sample] = []
    @Published private(set) var running = false

    private var timer: Timer?
    private var last: (time: Date, rx: UInt32, tx: UInt32)?

    func start() {
        guard timer == nil else { return }
        // Samples from a moment ago stay (the chart continues); after a longer gap they would join to the new line.
        if let l = samples.last, Date().timeIntervalSince(l.time) > 3 { samples = [] }
        last = nil
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    var current: Sample? { samples.last }

    private func tick() {
        let now = Date()
        var down = 0.0, up = 0.0
        if let c = Self.counters(address: Self.tunAddress) {
            running = true
            if let l = last {
                // A counter that went backwards means the interface was recreated: that second is zero.
                let dt = max(now.timeIntervalSince(l.time), 0.001)
                if c.rx >= l.rx { down = Double(c.rx - l.rx) / dt }
                if c.tx >= l.tx { up = Double(c.tx - l.tx) / dt }
            }
            last = (now, c.rx, c.tx)
        } else {
            running = false
            last = nil
        }
        samples = Self.appended(samples, Sample(time: now, down: down, up: up), keep: Self.window + 1)
    }

    /// The newest `keep` samples.
    nonisolated static func appended(_ s: [Sample], _ new: Sample, keep: Int) -> [Sample] {
        let all = s + [new]
        return all.count > keep ? Array(all.suffix(keep)) : all
    }

    /// Bytes received and sent on the interface that has `address`. In if_data, input is what comes back from the
    /// engine (download) and output is what applications send into the tun (upload). 32-bit counters, as getifaddrs gives.
    nonisolated static func counters(address: String) -> (rx: UInt32, tx: UInt32)? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var name: String?
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let sa = p.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
                var a = sin.pointee.sin_addr
                inet_ntop(AF_INET, &a, &buf, socklen_t(buf.count))
            }
            if String(cString: buf) == address { name = String(cString: p.pointee.ifa_name); break }
        }
        guard let name else { return nil }
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard String(cString: p.pointee.ifa_name) == name, let sa = p.pointee.ifa_addr,
                  sa.pointee.sa_family == UInt8(AF_LINK), let data = p.pointee.ifa_data else { continue }
            let d = data.assumingMemoryBound(to: if_data.self).pointee
            return (d.ifi_ibytes, d.ifi_obytes)
        }
        return nil
    }
}

/// "1.48 KB/s", "802 B/s".
func speedText(_ bytesPerSecond: Double) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .file) + "/s"
}
