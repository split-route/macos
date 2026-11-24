import XCTest
@testable import Splitroute

final class TrafficMonitorTests: XCTestCase {
    /// The interface lookup and the counters work on the one interface every Mac has; an unused address finds nothing.
    func testCountersByAddress() {
        let lo = TrafficMonitor.counters(address: "127.0.0.1")
        XCTAssertNotNil(lo)
        XCTAssertNil(TrafficMonitor.counters(address: "203.0.113.77"))
    }

    func testTheChartKeepsTheNewestSamples() {
        let t0 = Date(timeIntervalSince1970: 0)
        var s: [TrafficMonitor.Sample] = []
        for i in 0..<5 { s = TrafficMonitor.appended(s, .init(time: t0.addingTimeInterval(Double(i)), down: Double(i), up: 0), keep: 3) }
        XCTAssertEqual(s.map(\.down), [2, 3, 4])
    }
}
