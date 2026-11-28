import Foundation
import Network
import UserNotifications

// Smart Select (the switch on the Servers page, its rules in Settings > General): keeps the default route on the best server.
//
// A proxy server has no session of its own, so it never reports failed when its server goes down: the only way to know is
// to ask it. A check sends one request through each server worth comparing (the test's address and timeout) and picks one.
// It runs when Smart Select is turned on, on a schedule, when the Mac changes network, after a manual test, and when the
// active server stops answering (the health check: one request through it every so often, and three misses in a row).
// Rules it keeps:
// - Only the default selection moves (`selectTunnel`, which the engine switches to without a restart). A list or the default
//   route that names a server is never touched: it stays blocked while that server is down, never sent elsewhere.
// - OpenVPN servers are never chosen or left: they have sessions, and switching to one could send credentials the user
//   hasn't allowed. While one is active Smart Select does nothing.
// - A server is replaced only by one faster by more than the tolerance, so similar servers don't take turns.
// - A server that was just left isn't tried again for ten minutes; at most three automatic switches in half an hour.

enum SmartReason { case enabled, scheduled, network, failed, manual }

extension AppModel {
    static let probesToSwitch = 3
    static let maxSwitches = 3 // per half hour
    static let networkSettle: TimeInterval = 3

    // MARK: The rule

    /// The server to move to, or nil to stay. `results` holds the time of each server that answered (the active one included
    /// when it did). The active one is left when it didn't answer, or when another is faster by more than `tolerance` ms.
    static func smartPick(active: String?, results: [String: Int], tolerance: Int) -> String? {
        guard let best = results.min(by: { ($0.value, $0.key) < ($1.value, $1.key) }) else { return nil }
        guard let active else { return best.key }
        if best.key == active { return nil }
        guard let current = results[active] else { return best.key }
        return current - best.value > tolerance ? best.key : nil
    }

    /// Where Smart Select looks for a better server.
    enum SmartScope: Equatable {
        case all // every proxy server (the default)
        case group // the active server's group
        case custom(Set<Int64>) // the servers the person chose
    }

    /// The servers to compare: the active one first (its time is the one to beat), then proxy servers only, from the scope,
    /// none left in the last ten minutes. No limit: a long list takes the time it takes. Its own group comes first when the
    /// scope is every server.
    static func smartPool(_ all: [StoreTunnel], active: StoreTunnel, scope: SmartScope, failedAt: [String: Date], now: Date) -> [StoreTunnel] {
        var others = all.filter { !$0.isOpenVPN && $0.id != active.id && now.timeIntervalSince(failedAt[$0.name] ?? .distantPast) > 600 }
        switch scope {
        case .all: others = others.filter { $0.subscriptionID == active.subscriptionID } + others.filter { $0.subscriptionID != active.subscriptionID }
        case .group: others = others.filter { $0.subscriptionID == active.subscriptionID }
        case .custom(let ids): others = others.filter { ids.contains($0.id) }
        }
        return [active] + others
    }

    /// The scope the dropdown on the Servers page chose: every server unless it is the group or a custom list that holds servers.
    static func smartScope() -> SmartScope {
        let value = UserDefaults.standard.string(forKey: Prefs.smartScope) ?? "all"
        if value == "group" { return .group }
        if let id = SmartLists.listID(in: value), let list = SmartLists.load().first(where: { $0.id == id }), !list.servers.isEmpty {
            return .custom(Set(list.servers))
        }
        return .all
    }

    /// A server was removed: it leaves every custom list; if the list in use is empty now, Smart Select goes back to every server.
    func pruneSmartLists(existing: Set<Int64>) {
        let lists = SmartLists.load()
        let pruned = SmartLists.removing(missingFrom: existing, in: lists)
        if pruned != lists { SmartLists.save(pruned) }
        if let id = SmartLists.listID(in: UserDefaults.standard.string(forKey: Prefs.smartScope) ?? ""),
           pruned.first(where: { $0.id == id })?.servers.isEmpty ?? true {
            UserDefaults.standard.set("all", forKey: Prefs.smartScope)
        }
    }

    // MARK: The poll

    func runSmartSelect() async {
        guard Prefs.bool(Prefs.smartSelect, false), health == .active, !testing, !smartChecking, !busy,
              let sel = selectedTunnel, sel.protocolName != "openvpn", !serviceOutdated else {
            smartFailures = 0
            if !vpnOn { smartLastPass = .distantPast } // Smart Select is on again with the next connection: it checks at once
            return
        }
        let now = Date()
        if let until = smartPause, now < until { return }
        if let t = networkChangedAt, now.timeIntervalSince(t) >= Self.networkSettle {
            networkChangedAt = nil
            if Prefs.bool(Prefs.smartOnNetwork, true) { await smartPass(.network); return }
        }
        let every = TimeInterval(Prefs.int(Prefs.smartInterval, 1800))
        if every > 0, now.timeIntervalSince(smartLastPass) >= every { await smartPass(.scheduled); return }
        let hc = TimeInterval(Prefs.int(Prefs.smartHealth, 30))
        guard hc > 0, now.timeIntervalSince(lastProbe) >= (smartFailures > 0 ? 5 : hc) else { return }
        lastProbe = now
        smartChecking = true
        defer { smartChecking = false }
        if let id = try? stored(sel.name).coreID, case .ms = await Self.measure(id) {
            smartFailures = 0
            return
        }
        smartFailures += 1
        guard smartFailures >= Self.probesToSwitch else { return }
        smartFailures = 0
        await smartPass(.failed, alreadyChecking: true)
    }

    // MARK: A check

    /// One request through a server, with the test's address and timeout: its time, or why it didn't answer.
    nonisolated static func measure(_ id: String) async -> TunnelTest {
        let timeout = min(max(Prefs.int(Prefs.testTimeout, 5), Prefs.timeoutRange.lowerBound), Prefs.timeoutRange.upperBound)
        let url = Prefs.validTestURL(UserDefaults.standard.string(forKey: Prefs.testURL) ?? "") ?? Prefs.defaultTestURL
        guard let r = try? await Daemon.test([id], method: "connect", url: url, timeout: timeout)[id] else { return .failed("Failed", detail: nil) }
        if let e = r.error { return .failed(e, detail: r.detail?.nilIfEmpty) }
        return .ms(r.ms ?? 0)
    }

    /// Measures the servers worth comparing and moves to the best one (see the rules above); says what it did either way.
    func smartPass(_ reason: SmartReason, alreadyChecking: Bool = false) async {
        guard let sel = selectedTunnel, sel.protocolName != "openvpn" else {
            smartNote = "Smart Select works with proxy servers. The active OpenVPN server stays."
            return
        }
        guard !serviceOutdated, let store, let me = try? stored(sel.name), let all = try? store.tunnels() else { return }
        if !alreadyChecking { smartChecking = true }
        defer { smartChecking = false }
        let now = Date()
        smartLastPass = now
        if reason == .failed { failedAt[sel.name] = now }
        let scope = Self.smartScope()
        let pool = Self.smartPool(all, active: me, scope: scope, failedAt: failedAt, now: now)
        var results: [String: Int] = [:]
        // The rows show these numbers as a manual test would, and sorting by ping applies once the check is done.
        testing = true
        defer { testing = false }
        await withTaskGroup(of: (String, TunnelTest).self) { group in
            var it = pool.makeIterator()
            for _ in 0..<8 { if let t = it.next() { group.addTask { (t.name, await Self.measure(t.coreID)) } } }
            for await (name, result) in group {
                // Turned off in the middle of the check: stop, with nothing recorded or changed.
                if !vpnOn { group.cancelAll(); break }
                if case .failed(let why, _) = result, why == Self.vpnOffMessage { continue }
                testResults[name] = result
                if case .ms(let ms) = result { results[name] = ms }
                if let t = it.next() { group.addTask { (t.name, await Self.measure(t.coreID)) } }
            }
        }
        guard vpnOn else { return }
        await smartApply(results, reason: reason)
    }

    /// Moves to the server `smartPick` names, if any. A person who chose another server meanwhile is left alone.
    private func smartApply(_ results: [String: Int], reason: SmartReason) async {
        guard let sel = selectedTunnel else { return }
        let tolerance = Prefs.int(Prefs.smartTolerance, 100)
        let at = Date().formatted(date: .omitted, time: .shortened)
        guard let pick = Self.smartPick(active: sel.name, results: results, tolerance: tolerance),
              let target = tunnels.first(where: { $0.name == pick }) else {
            smartNote = results.isEmpty ? "Checked at \(at): no server answered. Nothing was changed."
                                        : "Checked at \(at): \(sel.name) stays the best server."
            if results[sel.name] == nil { smartPause = Date().addingTimeInterval(60) }
            return
        }
        let automatic = reason != .enabled && reason != .manual
        let now = Date()
        switchTimes = switchTimes.filter { now.timeIntervalSince($0) < 1800 }
        if automatic, switchTimes.count >= Self.maxSwitches {
            smartNote = "Checked at \(at): \(pick) is better, but servers were switched \(Self.maxSwitches) times in the last half hour, so nothing was changed."
            smartPause = now.addingTimeInterval(600)
            return
        }
        guard selectedTunnel?.name == sel.name else { return }
        _ = await selectTunnel(target)
        switchTimes.append(now)
        smartPause = now.addingTimeInterval(120) // let the new server settle before it is judged
        let why = results[sel.name] == nil ? "\(sel.name) stopped answering" : "\(target.name) is faster"
        smartNote = "Switched from \(sel.name) to \(target.name) at \(at): \(why)."
        if automatic { Self.notify("Server switched", "\(why), so Splitroute is now using \(target.name).") }
    }

    /// After a manual test: the same choice from the numbers it just measured, with no new requests.
    func smartApplyAfterTest() async {
        guard Prefs.bool(Prefs.smartSelect, false), Prefs.bool(Prefs.smartAfterTest, true), health == .active,
              TestMethod(rawValue: UserDefaults.standard.string(forKey: Prefs.testMethod) ?? "") ?? .connect == .connect,
              let sel = selectedTunnel, sel.protocolName != "openvpn", let store, let me = try? stored(sel.name), let all = try? store.tunnels() else { return }
        let pool = Self.smartPool(all, active: me, scope: Self.smartScope(), failedAt: failedAt, now: Date())
        var results: [String: Int] = [:]
        for t in pool { if case .ms(let ms)? = testResults[t.name] { results[t.name] = ms } }
        smartLastPass = Date()
        await smartApply(results, reason: .manual)
    }

    /// The title a server sits under in a list of servers: its subscription's name, or "Servers".
    static let handAddedTitle = "Servers"
    func groupTitle(of server: String) -> String { tunnels.first { $0.name == server }?.group ?? Self.handAddedTitle }

    struct SmartServer: Identifiable { let id: Int64; let name: String; let group: String?; let country: String }

    /// The proxy servers a custom list can hold, with their group's name.
    func smartServers() -> [SmartServer] {
        guard let store, let all = try? store.tunnels() else { return [] }
        let groups = Dictionary(uniqueKeysWithValues: ((try? store.subscriptions()) ?? []).map { ($0.id, $0.name) })
        return all.filter { !$0.isOpenVPN }.map { SmartServer(id: $0.id, name: $0.name, group: $0.subscriptionID.flatMap { groups[$0] }, country: $0.country) }
    }

    // MARK: Turning it on and off

    /// On: connects first when the connection is off (both turn on), then compares the servers and takes the best.
    func setSmartSelect(_ on: Bool) async {
        UserDefaults.standard.set(on, forKey: Prefs.smartSelect)
        smartFailures = 0
        smartNote = nil
        guard on else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
        if !vpnOn {
            smartChecking = true
            await setVPN(true)
            let running = await awaitEngine()
            smartChecking = false
            guard running else {
                smartNote = errors["vpn"] ?? "It didn't connect, so there is nothing to compare. See the server's message."
                return
            }
        }
        await smartPass(.enabled)
    }

    /// Waits for the engine to run after the connection was turned on (it starts after the host's settle time).
    func awaitEngine() async -> Bool {
        for _ in 0..<20 where service?.running != true {
            try? await Task.sleep(nanoseconds: 400_000_000)
            await refreshStatus()
        }
        return service?.running == true
    }

    // MARK: Network changes

    /// Notes when the Mac moves to another network (another interface, or back from none), ignoring the engine's own tunnel.
    func startNetworkWatch() {
        guard networkMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let real = path.availableInterfaces.filter { $0.type != .other }.map(\.name).sorted()
            let signature = (path.status == .satisfied ? "up:" : "down:") + real.joined(separator: ",")
            Task { @MainActor in
                guard let self else { return }
                if let old = self.networkSignature, old != signature, path.status == .satisfied { self.networkChangedAt = Date() }
                self.networkSignature = signature
            }
        }
        monitor.start(queue: DispatchQueue(label: "splitroute.network"))
        networkMonitor = monitor
    }

    private static func notify(_ title: String, _ body: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }
}
