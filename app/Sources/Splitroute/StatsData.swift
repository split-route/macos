import Foundation

// What the Statistics page shows for a range: which buckets, how they are grouped and what they add up to. Pure, so it is tested.

enum StatsRange: String, CaseIterable, Identifiable {
    case connection = "Connection", today = "Today", week = "Week", month = "Month", quarter = "3 Months"
    var id: String { rawValue }
}

enum StatsGranularity {
    case fiveMinutes, halfHour, hour, day

    /// How long one column is.
    var seconds: TimeInterval {
        switch self {
        case .fiveMinutes: return 300
        case .halfHour: return 1800
        case .hour: return 3600
        case .day: return 86400
        }
    }
}

/// Bytes in one chart column, split by who carried them.
struct TrafficPoint: Equatable, Identifiable {
    var date: Date
    var directDown = 0, proxyDown = 0, directUp = 0, proxyUp = 0
    /// How many 5-minute buckets went into it (only time the engine was recording has one) and the fastest second in any of them.
    var buckets = 0
    var peakDown = 0, peakUp = 0
    var id: Date { date }

    /// The average speed over the time recorded in the column, in bytes a second: its bytes over its buckets' seconds, so a
    /// half hour the connection was up for ten minutes is averaged over the ten.
    var avgDown: Double { buckets == 0 ? 0 : Double(directDown + proxyDown) / Double(buckets * Store.bucketSeconds) }
    var avgUp: Double { buckets == 0 ? 0 : Double(directUp + proxyUp) / Double(buckets * Store.bucketSeconds) }
}

struct TrafficTotals: Equatable {
    var directDown = 0, directUp = 0, proxyDown = 0, proxyUp = 0
    var peakDown = 0, peakUp = 0
    var down: Int { directDown + proxyDown }
    var up: Int { directUp + proxyUp }
}

enum StatsData {
    /// Where the range starts: the connection's start (nil when there is none), today's midnight, or that many days back.
    static func start(of range: StatsRange, now: Date, connectedSince: Date?, calendar: Calendar = .current) -> Date? {
        switch range {
        case .connection: return connectedSince
        case .today: return calendar.startOfDay(for: now)
        case .week: return calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now))
        case .month: return calendar.date(byAdding: .day, value: -29, to: calendar.startOfDay(for: now))
        case .quarter: return calendar.date(byAdding: .day, value: -89, to: calendar.startOfDay(for: now))
        }
    }

    /// Half hours for today, days for the longer ranges; a connection is shown by the 5 minutes until it is 3 hours old, then by the hour.
    static func granularity(of range: StatsRange, start: Date, now: Date) -> StatsGranularity {
        switch range {
        case .connection: return now.timeIntervalSince(start) <= 3 * 3600 ? .fiveMinutes : .hour
        case .today: return .halfHour
        case .week, .month, .quarter: return .day
        }
    }

    /// The time the chart spans: the whole range, so a month with one day of traffic is a thin bar among thirty empty days, not
    /// one wide bar. Today is the whole day; a connection runs from its start to now and is never narrower than half an hour.
    static func domain(of range: StatsRange, start: Date, now: Date, granularity g: StatsGranularity, calendar: Calendar = .current) -> ClosedRange<Date> {
        let unit = g.seconds
        var lower = start
        var upper = now
        switch g {
        case .day:
            lower = calendar.startOfDay(for: start)
            upper = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now.addingTimeInterval(unit)
        case .halfHour, .hour:
            lower = calendar.dateInterval(of: .hour, for: start)?.start ?? start
            upper = range == .today ? (calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now.addingTimeInterval(unit))
                                    : (calendar.dateInterval(of: .hour, for: now)?.end ?? now.addingTimeInterval(unit))
        case .fiveMinutes:
            lower = Date(timeIntervalSince1970: (start.timeIntervalSince1970 / 300).rounded(.down) * 300)
            upper = Date(timeIntervalSince1970: ((now.timeIntervalSince1970 / 300).rounded(.down) + 1) * 300)
            upper = max(upper, lower.addingTimeInterval(1800))
        }
        return lower...max(upper, lower.addingTimeInterval(unit))
    }

    /// The buckets summed into columns, oldest first, with no column for a time that had no traffic.
    static func points(_ rows: [TrafficBucket], by g: StatsGranularity, calendar: Calendar = .current) -> [TrafficPoint] {
        var by: [Date: TrafficPoint] = [:]
        for r in rows {
            let key: Date
            switch g {
            case .fiveMinutes: key = r.date
            case .halfHour:
                let hour = calendar.dateInterval(of: .hour, for: r.date)?.start ?? r.date
                key = r.date.timeIntervalSince(hour) >= 1800 ? hour.addingTimeInterval(1800) : hour
            case .hour: key = calendar.dateInterval(of: .hour, for: r.date)?.start ?? r.date
            case .day: key = calendar.startOfDay(for: r.date)
            }
            var p = by[key] ?? TrafficPoint(date: key)
            p.directDown += r.directDown; p.proxyDown += r.proxyDown; p.directUp += r.directUp; p.proxyUp += r.proxyUp
            p.buckets += 1
            p.peakDown = max(p.peakDown, r.peakDown); p.peakUp = max(p.peakUp, r.peakUp)
            by[key] = p
        }
        return by.values.sorted { $0.date < $1.date }
    }

    /// One column's two bars, both from the bottom: what a server carried and what went direct, download and upload together; the
    /// bigger first and the smaller drawn over it (so the column is as tall as the bigger one), whichever it is. A bar with no
    /// bytes is left out.
    static func segments(_ p: TrafficPoint) -> [(route: String, from: Int, to: Int)] {
        let server = p.proxyDown + p.proxyUp, direct = p.directDown + p.directUp
        let big = server >= direct ? ("Server", server) : ("Direct", direct)
        let small = server >= direct ? ("Direct", direct) : ("Server", server)
        var out: [(route: String, from: Int, to: Int)] = []
        if big.1 > 0 { out.append((big.0, 0, big.1)) }
        if small.1 > 0 { out.append((small.0, 0, small.1)) }
        return out
    }

    static func totals(_ rows: [TrafficBucket]) -> TrafficTotals {
        rows.reduce(into: TrafficTotals()) { t, r in
            t.directDown += r.directDown; t.directUp += r.directUp; t.proxyDown += r.proxyDown; t.proxyUp += r.proxyUp
            t.peakDown = max(t.peakDown, r.peakDown); t.peakUp = max(t.peakUp, r.peakUp)
        }
    }

    /// 30:02, or 1:05:30 from an hour on.
    static func uptime(_ seconds: TimeInterval) -> String {
        let s = max(Int(seconds), 0)
        let (h, m, sec) = (s / 3600, s % 3600 / 60, s % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%02d:%02d", m, sec)
    }
}
