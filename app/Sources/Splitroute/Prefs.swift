import Foundation

/// App-side preferences in UserDefaults. None of them changes what the engine runs, so none is in the snapshot or the
/// database: the app acts on them (when it updates, when it connects), and the connectivity test carries its own on the
/// `test` request.
enum Prefs {
    // Servers
    static let sortByPing = "sortByPing" // true: after a test, the fastest server first
    // Connection
    static let alwaysOn = "alwaysOn"
    static let disconnectOnSleep = "disconnectOnSleep"
    // Smart Select (AppModel+SmartSelect.swift). The key keeps its old name: it was "Switch servers automatically".
    static let smartSelect = "autoSwitch" // keep the active server the best one (default off)
    static let smartInterval = "smartInterval" // seconds between full latency checks; 0 never
    static let smartHealth = "smartHealth" // seconds between requests through the active server; 0 never
    static let smartTolerance = "smartTolerance" // ms a server must be faster by before it replaces the active one
    static let smartGroupOnly = "smartGroupOnly" // choose only among the active server's group
    static let smartPool = "smartPool" // most servers measured in one check
    static let smartOnNetwork = "smartOnNetwork" // check again when the Mac changes network
    static let smartAfterTest = "smartAfterTest" // move to the fastest server after a manual test
    static let showDisconnectMessage = "showDisconnectMessage"
    // Updates
    static let autoCheckUpdates = "autoCheckUpdates" // look for a newer app version once a day
    static let autoDownloadUpdates = "autoDownloadUpdates" // and fetch it when a check finds one (default on)
    static let subsUpdateOnOpen = "subsUpdateOnOpen"
    static let subsAutoUpdate = "subsAutoUpdate"
    static let subsIntervalHours = "subsIntervalHours"
    static let listsAutoUpdate = "listsAutoUpdate"
    static let listsUpdateOnOpen = "listsUpdateOnOpen"
    static let listsIntervalHours = "listsIntervalHours"
    static let subsLastAttempt = "subsLastAttempt" // when subscriptions were last tried (seconds since 1970), success or not
    static let listsLastAttempt = "listsLastAttempt"
    // Connectivity test
    static let testMethod = "testMethod"
    static let testTimeout = "testTimeout"
    static let testURL = "testURL"
    static let testCustomURL = "testCustomURL" // the address behind the "Custom" choice

    static let defaultTestURL = "https://www.gstatic.com/generate_204"
    /// Ready-made test addresses; the field stays editable.
    static let testURLPresets: [(name: String, url: String)] = [
        ("Google", "https://www.gstatic.com/generate_204"),
        ("Cloudflare", "https://cp.cloudflare.com/generate_204"),
        ("Apple", "https://captive.apple.com/hotspot-detect.html"),
        ("Google (www)", "https://www.google.com/generate_204"),
        ("Ubuntu", "https://connectivity-check.ubuntu.com/"),
        ("Fedora", "https://fedoraproject.org/static/hotspot.txt"),
        ("GNOME", "https://nmcheck.gnome.org/check_network_status.txt"),
    ]
    static let timeoutRange = 1...30
    static let smartIntervals = [0, 900, 1800, 3600, 10800, 28800] // seconds
    static let smartHealths = [0, 15, 30, 60, 300]
    static let smartTolerances = [0, 25, 50, 100, 200]
    static let smartPools = [8, 16, 24, 48, 100]
    static let subsIntervals = [1, 3, 6, 12, 24, 48, 168] // hours
    static let listsIntervals = [6, 12, 24, 48, 168]

    static func bool(_ key: String, _ fallback: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? fallback
    }

    static func int(_ key: String, _ fallback: Int) -> Int {
        UserDefaults.standard.object(forKey: key) as? Int ?? fallback
    }

    /// The address a test uses: https only, anything else falls back to the default.
    static func validTestURL(_ raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let u = URL(string: s), u.scheme?.lowercased() == "https", let h = u.host, !h.isEmpty, u.user == nil, s.count <= 2048 else { return nil }
        return s
    }
}
