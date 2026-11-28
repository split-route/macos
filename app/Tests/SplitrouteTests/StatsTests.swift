import XCTest
@testable import Splitroute

final class StatsTests: XCTestCase {
    private func cal() -> Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }
    private func date(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

    // MARK: Store

    func testAMergedBucketTakesTheHigherOfEachFieldSoAskingTwiceNeverCountsTwice() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("stats-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let s = try Store(path: dir.appendingPathComponent("db.sqlite").path)
        XCTAssertNil(try s.lastTrafficBucket())
        let filling = TrafficBucket(bucket: 10, directDown: 100, directUp: 10, proxyDown: 1000, proxyUp: 50, peakDown: 500, peakUp: 20)
        try s.mergeTraffic(filling)
        try s.mergeTraffic(filling) // the same answer again
        try s.mergeTraffic(TrafficBucket(bucket: 10, directDown: 150, directUp: 5, proxyDown: 1200, proxyUp: 50, peakDown: 300, peakUp: 90)) // it grew
        try s.mergeTraffic(TrafficBucket(bucket: 11, proxyDown: -5)) // nothing negative is stored
        let rows = try s.traffic(from: 10)
        XCTAssertEqual(rows[0], TrafficBucket(bucket: 10, directDown: 150, directUp: 10, proxyDown: 1200, proxyUp: 50, peakDown: 500, peakUp: 90))
        XCTAssertEqual(rows[1].proxyDown, 0)
        XCTAssertEqual(try s.lastTrafficBucket(), 11)
        XCTAssertEqual(try s.traffic(from: 11).count, 1, "from a bucket on")
        try s.clearTraffic()
        XCTAssertEqual(try s.traffic(from: 0), [])
        XCTAssertNil(try s.lastTrafficBucket())
    }

    func testRetentionKeepsThreeMonths() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("stats-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let s = try Store(path: dir.appendingPathComponent("db.sqlite").path)
        let now = Date()
        let old = Store.bucket(of: now.addingTimeInterval(-93 * 86400)), recent = Store.bucket(of: now.addingTimeInterval(-91 * 86400))
        try s.mergeTraffic(TrafficBucket(bucket: old, proxyDown: 1))
        try s.mergeTraffic(TrafficBucket(bucket: recent, proxyDown: 2))
        try s.pruneTraffic(now: now)
        XCTAssertEqual(try s.traffic(from: 0).map(\.bucket), [recent])
    }

    // MARK: Ranges

    func testRangesStartWhereTheySay() {
        let c = cal(), now = date("2026-11-28T14:30:00Z"), since = date("2026-11-28T13:00:00Z")
        XCTAssertEqual(StatsData.start(of: .connection, now: now, connectedSince: since, calendar: c), since)
        XCTAssertNil(StatsData.start(of: .connection, now: now, connectedSince: nil, calendar: c), "no connection, no range")
        XCTAssertEqual(StatsData.start(of: .today, now: now, connectedSince: nil, calendar: c), date("2026-11-28T00:00:00Z"))
        XCTAssertEqual(StatsData.start(of: .week, now: now, connectedSince: nil, calendar: c), date("2026-11-22T00:00:00Z"), "7 days with today")
        XCTAssertEqual(StatsData.start(of: .month, now: now, connectedSince: nil, calendar: c), date("2026-10-30T00:00:00Z"), "30 days")
        XCTAssertEqual(StatsData.start(of: .quarter, now: now, connectedSince: nil, calendar: c), date("2026-08-31T00:00:00Z"), "90 days")
    }

    func testGranularityGrowsWithTheRange() {
        let now = date("2026-11-28T14:30:00Z")
        XCTAssertEqual(StatsData.granularity(of: .connection, start: now.addingTimeInterval(-3600), now: now), .fiveMinutes)
        XCTAssertEqual(StatsData.granularity(of: .connection, start: now.addingTimeInterval(-4 * 3600), now: now), .hour)
        XCTAssertEqual(StatsData.granularity(of: .today, start: now, now: now), .halfHour, "today is shown by the half hour")
        for r in [StatsRange.week, .month, .quarter] { XCTAssertEqual(StatsData.granularity(of: r, start: now, now: now), .day) }
    }

    func testTheSmallerBarOverlapsTheBiggerFromTheBottom() {
        // Download and upload are added: server 100 + 40, direct 30 + 5.
        let a = StatsData.segments(TrafficPoint(date: Date(), directDown: 30, proxyDown: 100, directUp: 5, proxyUp: 40))
        XCTAssertEqual(a.map(\.route), ["Server", "Direct"], "the bigger first, so the smaller is drawn over it")
        XCTAssertEqual(a.map(\.from), [0, 0], "both start at the bottom")
        XCTAssertEqual(a.map(\.to), [140, 35])
        let b = StatsData.segments(TrafficPoint(date: Date(), directDown: 500, proxyDown: 20, directUp: 100, proxyUp: 1))
        XCTAssertEqual(b.map(\.route), ["Direct", "Server"], "direct is the bigger here, so it is behind")
        XCTAssertEqual(b.map(\.to), [600, 21])
        XCTAssertEqual(StatsData.segments(TrafficPoint(date: Date(), proxyUp: 7)).map(\.route), ["Server"], "a bar with nothing is left out")
        XCTAssertEqual(StatsData.segments(TrafficPoint(date: Date())).count, 0)
    }

    func testTheChartSpansTheWholeRange() {
        let c = cal(), now = date("2026-11-28T14:30:00Z")
        let month = StatsData.domain(of: .month, start: date("2026-10-30T00:00:00Z"), now: now, granularity: .day, calendar: c)
        XCTAssertEqual(month, date("2026-10-30T00:00:00Z")...date("2026-11-29T00:00:00Z"), "30 days, today included, even with one day of data")
        let today = StatsData.domain(of: .today, start: date("2026-11-28T00:00:00Z"), now: now, granularity: .halfHour, calendar: c)
        XCTAssertEqual(today, date("2026-11-28T00:00:00Z")...date("2026-11-29T00:00:00Z"), "the whole day")
        let young = StatsData.domain(of: .connection, start: date("2026-11-28T14:26:00Z"), now: now, granularity: .fiveMinutes, calendar: c)
        XCTAssertEqual(young.lowerBound, date("2026-11-28T14:25:00Z"))
        XCTAssertGreaterThanOrEqual(young.upperBound.timeIntervalSince(young.lowerBound), 1800, "never narrower than half an hour")
        let long = StatsData.domain(of: .connection, start: date("2026-11-28T08:10:00Z"), now: now, granularity: .hour, calendar: c)
        XCTAssertEqual(long, date("2026-11-28T08:00:00Z")...date("2026-11-28T15:00:00Z"))
    }

    func testBucketsAreSummedIntoHoursAndDays() {
        let c = cal()
        func bucket(_ s: String, down: Int) -> TrafficBucket { TrafficBucket(bucket: Store.bucket(of: date(s)), directDown: down, proxyDown: down * 10, peakDown: down) }
        let rows = [bucket("2026-11-27T23:55:00Z", down: 1), bucket("2026-11-28T10:05:00Z", down: 2), bucket("2026-11-28T10:55:00Z", down: 3), bucket("2026-11-28T11:00:00Z", down: 4)]
        let hours = StatsData.points(rows, by: .hour, calendar: c)
        XCTAssertEqual(hours.map(\.proxyDown), [10, 50, 40])
        XCTAssertEqual(hours.map(\.date), [date("2026-11-27T23:00:00Z"), date("2026-11-28T10:00:00Z"), date("2026-11-28T11:00:00Z")])
        let days = StatsData.points(rows, by: .day, calendar: c)
        XCTAssertEqual(days.map(\.directDown), [1, 9])
        XCTAssertEqual(StatsData.points(rows, by: .fiveMinutes, calendar: c).count, 4)
        let halves = StatsData.points(rows, by: .halfHour, calendar: c)
        XCTAssertEqual(halves.map(\.date), [date("2026-11-27T23:30:00Z"), date("2026-11-28T10:00:00Z"), date("2026-11-28T10:30:00Z"), date("2026-11-28T11:00:00Z")])
        XCTAssertEqual(halves.map(\.proxyDown), [10, 20, 30, 40], "05 to the first half, 55 to the second")
        let t = StatsData.totals(rows)
        XCTAssertEqual([t.down, t.proxyDown, t.directDown, t.peakDown], [110, 100, 10, 4], "totals add the classes; the peak is the highest bucket's")
    }

    /// The average speed is a column's bytes over the time that was recorded in it, not over the whole column.
    func testAverageSpeedIsOverTheRecordedTimeAndPeaksAreTheHighest() {
        let c = cal()
        func bucket(_ s: String, down: Int, up: Int, peak: Int) -> TrafficBucket {
            TrafficBucket(bucket: Store.bucket(of: date(s)), directDown: down / 2, proxyDown: down - down / 2, proxyUp: up, peakDown: peak, peakUp: peak / 2)
        }
        // Two 5-minute buckets inside one hour: 6,000,000 bytes down and 600,000 up over 600 s.
        let rows = [bucket("2026-11-28T10:00:00Z", down: 2_000_000, up: 100_000, peak: 900_000),
                    bucket("2026-11-28T10:05:00Z", down: 4_000_000, up: 500_000, peak: 400_000)]
        let hour = StatsData.points(rows, by: .hour, calendar: c)
        XCTAssertEqual(hour.count, 1)
        XCTAssertEqual(hour[0].buckets, 2)
        XCTAssertEqual(hour[0].avgDown, 10_000, accuracy: 0.001, "6 MB over the 600 s recorded, not over the hour")
        XCTAssertEqual(hour[0].avgUp, 1_000, accuracy: 0.001)
        XCTAssertEqual([hour[0].peakDown, hour[0].peakUp], [900_000, 450_000])
        XCTAssertEqual(TrafficPoint(date: Date()).avgDown, 0, "nothing recorded is not a division by zero")
    }

    func testUptimeIsMinutesThenHours() {
        XCTAssertEqual(StatsData.uptime(0), "00:00")
        XCTAssertEqual(StatsData.uptime(1802), "30:02")
        XCTAssertEqual(StatsData.uptime(3600 + 5 * 60 + 30), "1:05:30")
        XCTAssertEqual(StatsData.uptime(-5), "00:00", "a clock that moved back shows zero")
    }
}
