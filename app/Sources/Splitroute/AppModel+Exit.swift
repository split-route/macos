import Foundation

// The address the internet sees through the active server, for the Home card. The service looks it up through the server
// (a fixed address, `exit_ip`), so it is the server's address even when the default route is direct. It is looked up when
// the connection comes up or the active server changes, never on every poll.

extension AppModel {
    /// Called on every poll: starts a lookup when the connected server is a different one than last time.
    func followExitIP() {
        let key = health == .active ? selectedTunnel?.name : nil
        guard key != exitKey else { return }
        exitKey = key
        exitTask?.cancel()
        exitInfo = nil
        exitLookupFailed = false
        guard let key else { return }
        exitTask = Task { [weak self] in
            // The engine takes a moment after a switch; a lookup right away could still go through the old server.
            // A failed one is tried again a few times (the engine may be restarting).
            for wait in [1.5, 3.0, 8.0, 20.0] as [Double] {
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                guard let self, !Task.isCancelled, self.exitKey == key else { return }
                if let e = try? await Daemon.exitIP() {
                    guard !Task.isCancelled, self.exitKey == key else { return }
                    self.exitInfo = ExitInfo(ip: e.ip, country: Self.countryName(e.country), code: e.country)
                    self.exitLookupFailed = false
                    return
                }
            }
            if self?.exitKey == key { self?.exitLookupFailed = true }
        }
    }

    /// A country's English name for its two-letter code; the code itself when the system doesn't know it.
    nonisolated static func countryName(_ code: String?) -> String {
        guard let code, code.count == 2 else { return "" }
        return Locale(identifier: "en_US").localizedString(forRegionCode: code) ?? code
    }
}
