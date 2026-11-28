import XCTest
@testable import Splitroute

final class TrafficMonitorTests: XCTestCase {
    /// The interface lookup and the counters work on the one interface every Mac has; an unused address finds nothing.
    func testCountersByAddress() {
        let lo = TrafficMonitor.counters(address: "127.0.0.1")
        XCTAssertNotNil(lo)
        XCTAssertNil(TrafficMonitor.counters(address: "203.0.113.77"))
    }

    /// The chart keeps the last minute whatever the spacing: one-second samples (the window is open) or every five (the poll).
    func testTheChartKeepsTheLastWindowOfTime() {
        let t0 = Date(timeIntervalSince1970: 0)
        var s: [TrafficMonitor.Sample] = []
        for i in 0..<5 { s = TrafficMonitor.appended(s, .init(time: t0.addingTimeInterval(Double(i)), down: Double(i), up: 0), window: 2) }
        XCTAssertEqual(s.map(\.down), [2, 3, 4], "the newest two seconds, with the new one")
        var polled: [TrafficMonitor.Sample] = []
        for i in 0..<30 { polled = TrafficMonitor.appended(polled, .init(time: t0.addingTimeInterval(Double(i) * 5), down: Double(i), up: 0), window: 60) }
        XCTAssertEqual(polled.count, 13, "a minute of five-second samples is thirteen, not sixty-one")
        XCTAssertEqual(polled.last?.down, 29)
    }
}

final class SpeedTextTests: XCTestCase {
    func testBitsAreEightTimesTheBytesAndScaleWithTheSpeed() {
        XCTAssertEqual(speedText(0, unit: .mbps), "0 bps")
        XCTAssertEqual(speedText(50, unit: .mbps), "400 bps")
        XCTAssertEqual(speedText(1_250, unit: .mbps), "10.0 Kbps")
        XCTAssertEqual(speedText(1_000_000, unit: .mbps), "8.00 Mbps", "1 MB/s is 8 Mbps")
        XCTAssertEqual(speedText(12_500_000, unit: .mbps), "100 Mbps")
        XCTAssertEqual(speedText(125_000_000, unit: .mbps), "1.00 Gbps")
        XCTAssertEqual(speedText(-5, unit: .mbps), "0 bps", "a counter can't be negative")
    }

    func testBytesKeepTheOldWriting() {
        XCTAssertTrue(speedText(1_500_000, unit: .mbs).hasSuffix("MB/s"))
        XCTAssertEqual(SpeedUnit(rawValue: "nonsense"), nil)
    }

    func testTheSettingChoosesTheDefaultUnit() {
        let old = UserDefaults.standard.string(forKey: Prefs.speedUnit)
        defer { UserDefaults.standard.set(old, forKey: Prefs.speedUnit) }
        UserDefaults.standard.removeObject(forKey: Prefs.speedUnit)
        XCTAssertEqual(SpeedUnit.current, .mbps, "bits unless the person chose bytes")
        UserDefaults.standard.set("mbs", forKey: Prefs.speedUnit)
        XCTAssertEqual(SpeedUnit.current, .mbs)
    }
}

final class SpeedChartScaleTests: XCTestCase {
    func testTheTopIsARoundNumberAboveThePeakWithAMargin() {
        XCTAssertEqual(TrafficMonitor.niceTop(0), 10_000, "a quiet chart is never squeezed below 10 KB/s")
        XCTAssertEqual(TrafficMonitor.niceTop(11_600_000), 15_000_000, "a 93 Mbps peak gets 15 MB/s, not 50 MB/s")
        XCTAssertEqual(TrafficMonitor.niceTop(1_000_000), 1_500_000)
        XCTAssertEqual(TrafficMonitor.niceTop(4_000_000), 5_000_000)
        for peak in [3e3, 2e5, 7.7e6, 9.9e8] { XCTAssertGreaterThanOrEqual(TrafficMonitor.niceTop(peak), peak * 1.15) }
    }

    func testSmoothingTurnsANeedleIntoARoundedHill() {
        func s(_ t: Double, _ down: Double) -> TrafficMonitor.Sample { .init(time: Date(timeIntervalSince1970: t), down: down, up: 0) }
        let raw = (0..<21).map { s(Double($0), $0 == 10 ? 160 : 0) }
        let out = TrafficMonitor.smoothed(raw).map(\.down)
        XCTAssertEqual(out.count, raw.count)
        XCTAssertEqual(TrafficMonitor.smoothed(raw).map(\.time), raw.map(\.time))
        XCTAssertLessThan(out[10], 40, "the needle is a fraction of its height")
        XCTAssertGreaterThan(out[6], 0, "and it spreads four seconds either side")
        for i in 1..<10 { XCTAssertLessThanOrEqual(out[i - 1], out[i] + 1e-9, "rising to the middle") }
        for i in 10..<20 { XCTAssertGreaterThanOrEqual(out[i], out[i + 1] - 1e-9, "falling after it") }
        XCTAssertEqual(out[6], out[14], accuracy: 1e-9, "symmetric")
        XCTAssertEqual(out.reduce(0, +), 160, accuracy: 0.5, "the same traffic, spread out")
        XCTAssertEqual(TrafficMonitor.smoothed([s(0, 5), s(1, 9)]).map(\.down), [5, 9], "too few samples to smooth")
    }
}
