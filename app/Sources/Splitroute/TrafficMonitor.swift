import Darwin
import Foundation

/// Download and upload speed through the engine, from the byte counters of its tun interface. Everything the
/// engine carries goes through the tun (direct lists and all), so this is the Mac's traffic while it is connected.
/// No service call: the counters are public (getifaddrs). The app reads them once a second while the window is open (on any
/// page, so the chart is whole when you come back to Home), and on the poll, every few seconds, while it is closed, so the
/// chart already holds the last minute when the window opens.
@MainActor
final class TrafficMonitor: ObservableObject {
    struct Sample: Identifiable, Equatable {
        let time: Date
        let down: Double // bytes per second
        let up: Double
        var id: Date { time }
    }

    /// The samples smoothed three times with the weights 1-4-6-4-1 over sixteen (about a Gaussian a few seconds wide), so a one-second spike
    /// is a rounded hill and not a needle. The ends repeat their own value instead of dropping off. Only the drawing uses it: the
    /// figures shown are the real samples.
    nonisolated static func smoothed(_ s: [Sample]) -> [Sample] {
        guard s.count > 2 else { return s }
        func pass(_ v: [Double]) -> [Double] {
            let w: [Double] = [1, 4, 6, 4, 1]
            return v.indices.map { i in
                var sum = 0.0
                for (k, weight) in w.enumerated() { sum += weight * v[min(max(i + k - 2, 0), v.count - 1)] }
                return sum / 16
            }
        }
        let down = pass(pass(pass(s.map(\.down)))), up = pass(pass(pass(s.map(\.up))))
        return s.indices.map { Sample(time: s[$0].time, down: down[$0], up: up[$0]) }
    }

    /// The top of a speed chart: `peak` plus a margin, rounded up to 1, 1.5, 2, 3, 5 or 7.5 times a power of ten, and never below
    /// 10 KB/s. Finer steps than "5 or 10" keep a modest peak from squeezing everything into the bottom of the chart.
    nonisolated static func niceTop(_ peak: Double) -> Double {
        let v = max(peak * 1.15, 10_000)
        let e = pow(10, floor(log10(v)))
        let m = v / e
        return (([1, 1.5, 2, 3, 5, 7.5, 10].first { $0 >= m }) ?? 10) * e
    }

    /// The engine's tun address (core/build.go); the same coupling as `ksTunNet` in the daemon's kill switch.
    static let tunAddress = "172.19.0.1"
    static let window = 60 // seconds the chart shows
    /// Extra seconds kept beyond the window: the chart runs a moment behind the clock, so its left edge is older than the newest minute.
    static let overscan = 4
    /// Samples older than this when the window opens are not joined to the new line: more than two polls.
    static let staleAfter: TimeInterval = 12

    @Published private(set) var samples: [Sample] = []
    @Published private(set) var running = false

    private var timer: Timer?
    private var last: (time: Date, rx: UInt32, tx: UInt32)?

    func start() {
        guard timer == nil else { return }
        // Samples from a moment ago stay (the chart continues, and the background reads keep the counters' baseline); after a longer
        // gap they would join to the new line.
        if let l = samples.last, Date().timeIntervalSince(l.time) > Self.staleAfter { samples = []; last = nil }
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    /// A reading from the poll while the window is closed (every few seconds: a sample is the average over the gap). Nothing is read
    /// while there is no tun, and what was kept is forgotten, so a new connection's chart starts fresh.
    func sampleInBackground() {
        guard timer == nil else { return } // the window is open: the one-second timer reads
        guard Self.counters(address: Self.tunAddress) != nil else {
            if !samples.isEmpty { samples = []; last = nil }
            running = false
            return
        }
        tick()
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
        samples = Self.appended(samples, Sample(time: now, down: down, up: up), window: TimeInterval(Self.window + Self.overscan))
    }

    /// The samples of the last `window` seconds, with `new` added.
    nonisolated static func appended(_ s: [Sample], _ new: Sample, window: TimeInterval) -> [Sample] {
        (s + [new]).filter { new.time.timeIntervalSince($0.time) <= window }
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

/// How a speed is written (Settings > Application): in bits ("12.4 Mbps", what a speed test and a plan say) or in bytes
/// ("1.55 MB/s", what the Finder says). Sizes are bytes either way.
enum SpeedUnit: String, CaseIterable, Identifiable {
    case mbps, mbs
    var id: String { rawValue }
    var title: String { self == .mbps ? "Mbps" : "MB/s" }
    static var current: SpeedUnit { SpeedUnit(rawValue: UserDefaults.standard.string(forKey: Prefs.speedUnit) ?? "") ?? .mbps }
}

/// "12.4 Mbps" or "1.55 MB/s", by the setting; 0 is "0 bps" or "0 B/s".
func speedText(_ bytesPerSecond: Double, unit: SpeedUnit = .current) -> String {
    switch unit {
    case .mbs:
        return ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .file) + "/s"
    case .mbps:
        let bits = max(bytesPerSecond, 0) * 8
        let scales: [(Double, String)] = [(1e9, "Gbps"), (1e6, "Mbps"), (1e3, "Kbps")]
        guard let (scale, name) = scales.first(where: { bits >= $0.0 }) else { return "\(Int(bits)) bps" }
        let v = bits / scale
        return String(format: v < 10 ? "%.2f %@" : v < 100 ? "%.1f %@" : "%.0f %@", v, name)
    }
}
