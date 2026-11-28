import Foundation
import GRDB

// Statistics: the engine's byte counters, kept in 5-minute buckets for three months (see migration 24).

struct TrafficBucket: Equatable {
    /// Seconds since 1970 divided by `Store.bucketSeconds`.
    var bucket: Int
    var directDown = 0, directUp = 0, proxyDown = 0, proxyUp = 0
    /// The fastest second in the bucket, in bytes.
    var peakDown = 0, peakUp = 0

    var date: Date { Date(timeIntervalSince1970: TimeInterval(bucket * Store.bucketSeconds)) }
    var down: Int { directDown + proxyDown }
    var up: Int { directUp + proxyUp }
}

extension Store {
    static let bucketSeconds = 300
    /// How long statistics are kept.
    static let trafficRetentionDays = 92

    static func bucket(of date: Date) -> Int { Int(date.timeIntervalSince1970) / bucketSeconds }

    /// Stores a bucket the service reported. The service sends a bucket whole and again while it is still filling, so each field
    /// takes the higher of what is stored and what came: asking twice never counts twice.
    func mergeTraffic(_ t: TrafficBucket) throws {
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO traffic (bucket, direct_down, direct_up, proxy_down, proxy_up, peak_down, peak_up) VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT (bucket) DO UPDATE SET direct_down = max(direct_down, excluded.direct_down), direct_up = max(direct_up, excluded.direct_up),
                    proxy_down = max(proxy_down, excluded.proxy_down), proxy_up = max(proxy_up, excluded.proxy_up),
                    peak_down = max(peak_down, excluded.peak_down), peak_up = max(peak_up, excluded.peak_up)
                """, arguments: [t.bucket, max(t.directDown, 0), max(t.directUp, 0), max(t.proxyDown, 0), max(t.proxyUp, 0), max(t.peakDown, 0), max(t.peakUp, 0)])
        }
    }

    /// The newest bucket stored, or nil.
    func lastTrafficBucket() throws -> Int? {
        try queue.read { try Int.fetchOne($0, sql: "SELECT max(bucket) FROM traffic") }
    }

    /// The buckets from `bucket` on, oldest first.
    func traffic(from bucket: Int) throws -> [TrafficBucket] {
        try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM traffic WHERE bucket >= ? ORDER BY bucket", arguments: [bucket]).map {
                TrafficBucket(bucket: $0["bucket"], directDown: $0["direct_down"], directUp: $0["direct_up"], proxyDown: $0["proxy_down"],
                              proxyUp: $0["proxy_up"], peakDown: $0["peak_down"], peakUp: $0["peak_up"])
            }
        }
    }

    /// Forgets what is older than the retention.
    func pruneTraffic(now: Date = Date()) throws {
        let cutoff = Store.bucket(of: now.addingTimeInterval(-TimeInterval(Store.trafficRetentionDays) * 86400))
        try queue.write { try $0.execute(sql: "DELETE FROM traffic WHERE bucket < ?", arguments: [cutoff]) }
    }

    func clearTraffic() throws {
        try queue.write { try $0.execute(sql: "DELETE FROM traffic") }
    }
}
