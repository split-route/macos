import Foundation
import UserNotifications

// Moves the default route to another server when the active one stops answering. Off by default (Settings > Network).
//
// A proxy server has no session of its own, so it never reports failed when its server goes down: the only way to know
// is to ask it. While connected the app sends one request through the active server every 30 s (the test's address and
// timeout) and, once three in a row have failed (the second and third a few seconds after the one before), measures a few
// others and takes the quickest. Rules it keeps:
// - Only the default selection moves (`selectTunnel`, which the engine switches to without a restart). A list or the default
//   route that names a server is never touched: it stays blocked while that server is down, never sent elsewhere.
// - OpenVPN servers are never chosen or left: they have sessions, and switching to one could send credentials the user
//   hasn't allowed.
// - A server that was just left isn't tried again for ten minutes; at most three switches in half an hour.

extension AppModel {
    static let probeEvery: TimeInterval = 30
    static let probesToSwitch = 3
    static let maxSwitches = 3 // per half hour
    static let candidatePool = 24

    func runFailover() async {
        guard Prefs.bool(Prefs.autoSwitch, false), health == .active, !testing, !failoverBusy, !busy,
              let sel = selectedTunnel, sel.protocolName != "openvpn", !serviceOutdated else {
            probeFailures = 0
            return
        }
        let now = Date()
        if let until = failoverPause, now < until { return }
        if now.timeIntervalSince(lastProbe) < (probeFailures > 0 ? 5 : Self.probeEvery) { return }
        lastProbe = now
        failoverBusy = true
        defer { failoverBusy = false }
        if await probe(name: sel.name) != nil {
            probeFailures = 0
            return
        }
        probeFailures += 1
        guard probeFailures >= Self.probesToSwitch else { return }
        probeFailures = 0
        await failOver(from: sel)
    }

    /// One request through a server, with the test's address and timeout: its time in ms, or nil when it didn't answer.
    private func probe(name: String) async -> Int? {
        guard let id = try? stored(name).coreID else { return nil }
        return await Self.measure(id)
    }

    nonisolated private static func measure(_ id: String) async -> Int? {
        let timeout = min(max(Prefs.int(Prefs.testTimeout, 5), Prefs.timeoutRange.lowerBound), Prefs.timeoutRange.upperBound)
        let url = Prefs.validTestURL(UserDefaults.standard.string(forKey: Prefs.testURL) ?? "") ?? Prefs.defaultTestURL
        guard let r = try? await Daemon.test([id], method: "connect", url: url, timeout: timeout)[id], r.error == nil else { return nil }
        return r.ms ?? 0
    }

    /// The servers worth measuring to replace `me`: proxy servers only, not `me`, not one left in the last ten minutes; the same
    /// subscription first (the servers the person meant to use together), at most `candidatePool`.
    static func failoverPool(_ all: [StoreTunnel], leaving me: StoreTunnel, failedAt: [String: Date], now: Date) -> [StoreTunnel] {
        let fresh = all.filter { !$0.isOpenVPN && $0.id != me.id && now.timeIntervalSince(failedAt[$0.name] ?? .distantPast) > 600 }
        return Array((fresh.filter { $0.subscriptionID == me.subscriptionID } + fresh.filter { $0.subscriptionID != me.subscriptionID }).prefix(candidatePool))
    }

    /// Picks the quickest other proxy server and makes it the default; says what happened either way.
    private func failOver(from sel: Tunnel) async {
        let now = Date()
        switchTimes = switchTimes.filter { now.timeIntervalSince($0) < 1800 }
        guard switchTimes.count < Self.maxSwitches else {
            lastFailover = "\(sel.name) isn't answering, but servers were switched \(Self.maxSwitches) times in the last half hour, so nothing was changed."
            failoverPause = now.addingTimeInterval(600)
            return
        }
        failedAt[sel.name] = now
        guard let store, let me = try? stored(sel.name), let all = try? store.tunnels() else { return }
        let pool = Self.failoverPool(all, leaving: me, failedAt: failedAt, now: now)
        failoverBusy = true
        var best: (name: String, ms: Int)?
        await withTaskGroup(of: (String, Int?).self) { group in
            var it = pool.makeIterator()
            for _ in 0..<8 { if let t = it.next() { group.addTask { (t.name, await Self.measure(t.coreID)) } } }
            for await (name, ms) in group {
                if let ms, ms < (best?.ms ?? Int.max) { best = (name, ms) }
                if let t = it.next() { group.addTask { (t.name, await Self.measure(t.coreID)) } }
            }
        }
        // The person may have chosen another server meanwhile: then there is nothing to do.
        guard let best, let target = tunnels.first(where: { $0.name == best.name }), selectedTunnel?.name == sel.name else {
            lastFailover = "\(sel.name) isn't answering and no other server did. Nothing was changed."
            failoverPause = now.addingTimeInterval(60)
            return
        }
        _ = await selectTunnel(target)
        switchTimes.append(now)
        failoverPause = now.addingTimeInterval(120) // let the new server settle before it is judged
        lastFailover = "Switched from \(sel.name) to \(target.name) at \(now.formatted(date: .omitted, time: .shortened)): \(sel.name) stopped answering."
        Self.notify("Server switched", "\(sel.name) stopped answering, so Splitroute is now using \(target.name).")
    }

    private static func notify(_ title: String, _ body: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    /// Asks for permission to post when the setting is turned on.
    func setAutoSwitch(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Prefs.autoSwitch)
        probeFailures = 0
        if on { UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in } }
    }
}
