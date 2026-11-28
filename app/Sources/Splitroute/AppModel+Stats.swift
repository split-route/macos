import Foundation

// Statistics: the service logs what the engine carries by time (`trafficlog.go`, in memory); while "Record statistics" is on the app
// asks on every poll for the buckets after the last one it has stored and keeps them in the database. A period the app was closed
// arrives as the buckets it was. A bucket still filling is sent again and merged (each field takes the higher), so asking twice
// never counts twice. A service restart empties the service's log: what the app hadn't pulled is lost.

extension AppModel {
    private static let fromKey = "statsFrom"

    /// Called from the poll: stores the buckets the service has that the app doesn't.
    func recordTraffic() async {
        let day = Int(Date().timeIntervalSince1970 / 86400)
        if statsPrunedDay != day { statsPrunedDay = day; pruneStats() } // once at launch, then daily
        guard Prefs.bool(Prefs.recordStats, true), connError == nil, let store, !serviceOutdated else { return }
        // From the newest stored bucket (it may have been filling), and never from before a reset.
        let cutoff = UserDefaults.standard.integer(forKey: Self.fromKey)
        let from = max((try? store.lastTrafficBucket()) ?? 0, cutoff)
        guard let buckets = try? await Daemon.traffic(since: from), !buckets.isEmpty else { return }
        for b in buckets {
            try? store.mergeTraffic(TrafficBucket(bucket: b.bucket, directDown: b.directDown, directUp: b.directUp, proxyDown: b.proxyDown,
                                                  proxyUp: b.proxyUp, peakDown: b.peakDown, peakUp: b.peakUp))
        }
    }

    /// Turns recording on or off. The service attaches its counter as the engine starts, so turning it on while connected
    /// restarts the connection once; off, the counter stays idle.
    func setRecordStats(_ on: Bool) async {
        UserDefaults.standard.set(on, forKey: Prefs.recordStats)
        link?.recordStats = on
        await edit("recordStats") { }
    }

    /// Deletes the recorded statistics.
    func resetStats() {
        try? store?.clearTraffic()
        // The service still has its log: only buckets from now on are wanted.
        UserDefaults.standard.set(Store.bucket(of: Date()), forKey: Self.fromKey)
        statsRevision += 1
    }

    /// Forgets what is older than three months; once at launch and then daily.
    func pruneStats() {
        try? store?.pruneTraffic()
    }

    /// When the VPN switch was turned on, from the service (it survives a restart of the engine and of this app).
    var connectedSince: Date? {
        service?.connectedSince.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) }
    }
}
