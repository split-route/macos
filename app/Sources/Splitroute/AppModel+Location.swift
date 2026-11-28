import Foundation

/// Where each server is: the service resolves its name and looks the address up in a database it carries (nothing is
/// asked of anyone), the app stores the country and shows a flag. A server is looked up when it is added, when its
/// subscription is updated or its address edited, once after an upgrade, and daily for the servers no subscription
/// refreshes (a name can move to another country without the config changing).
extension AppModel {
    /// How long a standalone server's country stands before it is looked up again.
    nonisolated static let locateEvery: TimeInterval = 24 * 3600

    /// Asks the service about these servers (row IDs; it must already have the snapshot that holds them) and stores the
    /// answers. Quiet on any failure: an older service, no network or a name that doesn't resolve leave the flag as it was.
    func locateServers(_ ids: [Int64]) async {
        guard let store, !ids.isEmpty else { return }
        for chunk in stride(from: 0, to: ids.count, by: Daemon.maxLocate).map({ Array(ids[$0..<min($0 + Daemon.maxLocate, ids.count)]) }) {
            guard let answer = try? await Daemon.serverCountries(chunk.map { "t\($0)" }) else { return }
            var found: [Int64: String] = [:]
            for (key, code) in answer where key.hasPrefix("t") { if let id = Int64(key.dropFirst()) { found[id] = code } }
            try? store.setCountries(found)
            reloadLocal()
        }
    }

    /// The servers that are due: never looked up, or older than a day when standalone (no subscription) or when the country
    /// is unknown (that may be a name that didn't resolve then).
    nonisolated static func dueForLocation(_ ts: [StoreTunnel], now: Date = Date()) -> [Int64] {
        let cutoff = Int(now.timeIntervalSince1970 - locateEvery)
        return ts.filter { $0.countryAt == 0 || (($0.subscriptionID == nil || $0.country.isEmpty) && $0.countryAt < cutoff) }.map(\.id)
    }

    /// Called from the poll: looks up what is due, once at a time.
    func locateDueServers() async {
        guard !locating, service != nil, let all = try? store?.tunnels() else { return }
        let due = Self.dueForLocation(all)
        guard !due.isEmpty else { return }
        locating = true
        defer { locating = false }
        await locateServers(due)
    }
}
