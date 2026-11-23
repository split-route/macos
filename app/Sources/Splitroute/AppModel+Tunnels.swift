import Foundation
import Design

// Tunnels, subscriptions, the VPN switch. The database holds the metadata, 0600 files hold what a tunnel runs and a
// subscription's address, the Keychain holds credentials; the service gets all of it in the next snapshot.

extension TunnelSecrets {
    var isEmpty: Bool { username.isEmpty && password.isEmpty && keyPassword.isEmpty }
}

extension AppModel {
    var tunnels: [Tunnel] { tunnelList?.tunnels ?? [] }

    private func stored(_ name: String) throws -> StoreTunnel {
        guard let t = try store?.tunnels().first(where: { $0.name == name }) else { throw StoreError("No tunnel named \"\(name)\".") }
        return t
    }

    private func subscription(_ name: String) throws -> StoreSubscription {
        guard let s = try store?.subscriptions().first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            throw StoreError("No subscription named \"\(name)\".")
        }
        return s
    }

    // MARK: Credentials

    /// A tunnel waiting for credentials that this run or the Keychain has: they go out with the next snapshot, or, for a
    /// running tunnel that asks again (a challenge), straight to it. At most once a minute per tunnel, so a denied
    /// Keychain prompt isn't hammered.
    func supplyTunnelCredentials() async {
        guard let link else { return }
        for t in tunnels where t.state == .needsAuth {
            if credentialsRefused.contains(t.name) { continue } // the server refused them: ask, don't re-send
            if let last = tunnelSupplied[t.name], Date().timeIntervalSince(last) < 60 { continue }
            tunnelSupplied[t.name] = Date()
            guard let s = sessionSecrets[t.name] ?? TunnelKeychain.load(t.name), !(s.username.isEmpty && s.password.isEmpty) else { continue }
            if let id = try? stored(t.name).coreID, link.sentCredentials.contains(t.name) {
                try? await Daemon.answer(id, username: s.username, password: s.password)
            } else {
                link.markDirty()
            }
        }
    }

    /// Connecting needs a prompt when the profile wants credentials and none are saved.
    func needsCredentialPrompt(_ t: Tunnel) -> Bool {
        (t.needsAuth || t.keyEncrypted) && sessionSecrets[t.name] == nil && TunnelKeychain.load(t.name) == nil
    }

    func connectTunnel(_ t: Tunnel, secrets: TunnelSecrets? = nil, remember: Bool = false) async {
        if let secrets {
            if remember { TunnelKeychain.save(t.name, secrets) } else { sessionSecrets[t.name] = secrets }
            credentialsRefused.remove(t.name) // new credentials from the user
        }
        errors["tunnel:\(t.name)"] = nil
        if let id = try? stored(t.name).coreID { link?.retry(id) }
        await changed()
        await followTunnel(t.name)
    }

    /// Credentials for a tunnel that is running and asks for them (a challenge), or that waits for them.
    func answerCredentials(_ t: Tunnel, secrets: TunnelSecrets, remember: Bool) async {
        if remember { TunnelKeychain.save(t.name, secrets) } else { sessionSecrets[t.name] = secrets }
        credentialsRefused.remove(t.name)
        if t.state == .needsAuth, let id = try? stored(t.name).coreID, link?.sentCredentials.contains(t.name) == true {
            try? await Daemon.answer(id, username: secrets.username, password: secrets.password)
        } else {
            await changed()
        }
    }

    /// Re-reads the tunnel every second until it settles, so the switch reflects the progress.
    private func followTunnel(_ name: String) async {
        for _ in 0..<20 {
            await refreshStatus()
            reloadLocal()
            if let t = tunnels.first(where: { $0.name == name }), [.connected, .ready, .failed, .needsAuth, .disconnected].contains(t.state) { return }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    // MARK: The VPN switch and the selected tunnel

    /// Whether the user has the VPN on.
    var vpnOn: Bool { tunnelList?.vpn ?? false }

    /// The tunnel that carries all traffic no list names.
    var selectedTunnel: Tunnel? {
        guard let n = tunnelList?.selected else { return nil }
        return tunnels.first { $0.name == n }
    }

    /// Turns the VPN on or off. Turning it on with no tunnel selected selects the first; with no tunnels it is refused.
    func setVPN(_ on: Bool) async {
        errors["vpn"] = nil
        do {
            guard let store else { throw StoreError("The settings database isn't open.") }
            if on {
                let ts = try store.tunnels()
                guard !ts.isEmpty else { throw StoreError("Add a tunnel first.") }
                if try store.vpn().selected == nil { try store.setSelected(ts[0].id) }
                link?.retry("*") // the user asked: tunnels that failed may be tried again
            }
            try store.setVPN(on: on)
            if !on { testResults = [:] } // the tunnels stop running: the numbers no longer mean anything
        } catch { errors["vpn"] = error.localizedDescription }
        await changed()
    }

    /// How proxy tunnels' server names are found: "" (the service's default, Google DoH), a DoH server's address, or
    /// "system". 8.8.8.8 is the default, so it is shown as "".
    var bootstrap: String { tunnelList?.bootstrap == "8.8.8.8" ? "" : tunnelList?.bootstrap ?? "" }

    func setBootstrap(_ value: String) async {
        errors["bootstrap"] = nil
        do {
            guard let store else { throw StoreError("The settings database isn't open.") }
            try store.setBootstrap(value)
            link?.retry("*") // the tunnels that failed to find their server may be tried again
        } catch { errors["bootstrap"] = error.localizedDescription }
        await changed()
    }

    var killSwitchOn: Bool { tunnelList?.killSwitch ?? false }
    var killSwitchLAN: Bool { tunnelList?.killSwitchLAN ?? true }
    /// The firewall rules are loaded: traffic that isn't the VPN's is blocked, so a dropped tunnel means no network.
    var killSwitchArmed: Bool { tunnelList?.killSwitchArmed ?? false }

    func setKillSwitch(on: Bool? = nil, lan: Bool? = nil) async {
        errors["killswitch"] = nil
        do {
            guard let store else { throw StoreError("The settings database isn't open.") }
            try store.setKillSwitch(on: on, lan: lan)
        } catch { errors["killswitch"] = error.localizedDescription }
        await changed()
    }

    /// Chooses the tunnel for all traffic no list names. While the VPN is on, the engine switches to it without
    /// restarting. Returns true when the credentials sheet should open: the tunnel needs credentials that aren't saved,
    /// or the server refused the saved ones (those are never sent again without asking).
    func selectTunnel(_ t: Tunnel) async -> Bool {
        errors["tunnel:\(t.name)"] = nil
        let refused = t.state == .failed && Self.credentialsRefused(t.error)
        if refused { credentialsRefused.insert(t.name) }
        do {
            let st = try stored(t.name)
            try store?.setSelected(st.id)
            link?.retry(st.coreID)
        } catch {
            errors["tunnel:\(t.name)"] = error.localizedDescription
            return false
        }
        await changed()
        guard vpnOn else { return false }
        return refused || (tunnels.first { $0.name == t.name }.map { $0.state == .needsAuth && needsCredentialPrompt($0) } ?? false)
    }

    static func credentialsRefused(_ error: String?) -> Bool {
        guard let e = error else { return false }
        return e.contains("username or password") || e.contains("key password")
    }

    // MARK: Connectivity test

    /// Sends one request through every tunnel and shows how long each took, or "Timeout". With the VPN off it turns it
    /// on first and leaves it on. OpenVPN tunnels that aren't in use are loaded for the test (their sessions come up,
    /// which takes a few seconds) and put away again after. A tunnel that failed earlier stays failed, with its message:
    /// a test never retries credentials. One that needs a sign-in says so.
    func testConnectivity() async {
        guard !testing else { return }
        errors["test"] = nil
        if serviceOutdated {
            errors["test"] = "The service is older than this app and can't run this test. Restart it (Settings → Advanced → Restart service), or reinstall the app's service."
            return
        }
        guard let store, let all = try? store.tunnels(), !all.isEmpty, let link else { return }
        testing = true
        defer { testing = false }
        testResults = [:]
        if !vpnOn {
            await setVPN(true)
            if let e = errors["vpn"] { errors["test"] = e; return }
            // The engine starts after the settle time; wait until it runs.
            for _ in 0..<20 where service?.running != true {
                try? await Task.sleep(nanoseconds: 400_000_000)
                await refreshStatus()
            }
            guard service?.running == true else {
                errors["test"] = "The VPN didn't start, so there is nothing to test. See the tunnel's message."
                return
            }
        }
        let openVPN = all.filter(\.isOpenVPN)
        link.loadAll = true
        await changed()
        defer { Task { link.loadAll = false; await changed() } } // the extra sessions go away
        // Wait for each OpenVPN session to come up, fail or ask for a sign-in.
        for _ in 0..<50 where openVPN.contains(where: { ![.connected, .failed, .needsAuth].contains(service?.tunnels[$0.coreID]?.state) }) {
            try? await Task.sleep(nanoseconds: 500_000_000)
            await refreshStatus()
        }
        let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.coreID, $0.name) })
        // One call per tunnel, a few at a time (the service's own width), so each result shows when it is in
        // instead of when the slowest one is.
        var ids = all.map(\.coreID).makeIterator()
        let one: @Sendable (String) async -> (String, WireTest?, Error?) = { id in
            do { return (id, try await Daemon.test([id])[id], nil) } catch { return (id, nil, error) }
        }
        await withTaskGroup(of: (String, WireTest?, Error?).self) { group in
            for _ in 0..<8 { if let id = ids.next() { group.addTask { await one(id) } } }
            for await (id, r, err) in group {
                if let err {
                    errors["test"] = err.localizedDescription
                    group.cancelAll()
                    break
                }
                if let r, let name = byID[id] {
                    switch service?.tunnels[id]?.state {
                    case .failed?: testResults[name] = .failed("Failed", detail: service?.tunnels[id]?.error?.nilIfEmpty)
                    case .needsAuth?: testResults[name] = .failed("Needs sign-in", detail: nil)
                    default: testResults[name] = r.error.map { .failed($0, detail: r.detail?.nilIfEmpty) } ?? .ms(r.ms ?? 0)
                    }
                }
                if let next = ids.next() { group.addTask { await one(next) } }
            }
        }
    }

    // MARK: Adding

    /// Returns the error, or nil when the tunnel was added.
    func importTunnel(name: String, text: String, secrets: TunnelSecrets?) async -> String? {
        let e = await attempt {
            guard let store = self.store else { throw StoreError("The settings database isn't open.") }
            let check = try await Daemon.checkProfile(text)
            if let why = check.refused?.nilIfEmpty { throw StoreError(why) }
            let clean = Store.cleanName(name)
            if try store.tunnels().contains(where: { $0.name.caseInsensitiveCompare(clean) == .orderedSame }) {
                throw StoreError("A tunnel with that name already exists.")
            }
            let data = Data(text.utf8)
            var t = StoreTunnel(id: 0, name: clean, kind: "openvpn", sha: AppFiles.sha256(data), remotes: check.remotes ?? [])
            t.needsAuth = check.needsAuth
            t.keyEncrypted = check.keyEncrypted
            let added = try store.addTunnels([t]).tunnels[0]
            do { try self.files.writeTunnelSource(added, data) } catch {
                try? store.removeTunnel(added.id)
                self.files.removeTunnelFiles(added.id)
                throw error
            }
            if let secrets, !secrets.isEmpty { TunnelKeychain.save(added.name, secrets) }
        }
        return e
    }

    /// What a profile asks for, before it is imported.
    func checkTunnel(text: String) async -> Result<TunnelCheck, Error> {
        do { return .success(try await Daemon.checkProfile(text)) } catch { return .failure(error) }
    }

    /// Imports share links or a subscription. `url` is kept as a subscription (named `name`, or by its host); `text` is
    /// pasted links, a subscription body or one address. Nodes the engine can't run are skipped with a reason.
    func addTunnels(text: String?, url: String?, name: String?) async -> Result<AddResult, Error> {
        busy = true
        defer { busy = false }
        do {
            guard let store else { throw StoreError("The settings database isn't open.") }
            var raw = url?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            var body = text ?? ""
            if raw == nil, Fetch.looksLikeURL(body.trimmingCharacters(in: .whitespacesAndNewlines)) {
                raw = body.trimmingCharacters(in: .whitespacesAndNewlines)
                body = ""
            }
            var u: URL?
            var usage: SubscriptionUsage?
            if let raw {
                u = try Fetch.checkSubscriptionURL(raw)
                (body, usage) = try await Fetch.subscription(u!)
            }
            let parsed: WireNodes
            do { parsed = try await Daemon.parseLinks(body) } catch let DaemonError.failed(m) where u != nil {
                throw StoreError("\(u?.host ?? "The server") did not return a subscription: \(m)")
            }
            var res = AddResult(added: 0, skipped: parsed.skipped, group: nil)
            let (rows, datas) = try nodes(parsed)
            guard !rows.isEmpty else { return .success(res) } // nothing to store; the sheet shows why each was skipped
            let (sub, added) = try store.addTunnels(rows, subscription: u.map { _ in name?.nilIfEmpty ?? u?.host ?? "Subscription" })
            do {
                for (i, t) in added.enumerated() { try files.writeTunnelSource(t, datas[i]) }
                if let sub, let u {
                    try files.writeSubscriptionURL(sub.id, u.absoluteString)
                    files.saveUsage(sub.id, usage)
                    res.group = sub.name
                }
            } catch {
                for t in added { files.removeTunnelFiles(t.id) }
                if let sub { files.removeSubscriptionFiles(sub.id); try? store.removeSubscription(sub.id) } else { for t in added { try? store.removeTunnel(t.id) } }
                throw error
            }
            res.added = added.count
            await changed()
            return .success(res)
        } catch {
            return .failure(error)
        }
    }

    /// The nodes as rows and the bytes of the options file each row's hash covers.
    private func nodes(_ parsed: WireNodes) throws -> (rows: [StoreTunnel], datas: [Data]) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var rows: [StoreTunnel] = [], datas: [Data] = []
        for n in parsed.nodes {
            let data = try enc.encode(n.options)
            var t = StoreTunnel(id: 0, name: n.name, kind: n.protocol, sha: AppFiles.sha256(data), remotes: [n.server])
            t.warning = n.warning ?? ""
            rows.append(t)
            datas.append(data)
        }
        return (rows, datas)
    }

    // MARK: Removing and renaming

    func removeTunnel(_ name: String) async {
        errors["tunnel:\(name)"] = await attempt {
            guard let store = self.store else { return }
            let t = try self.stored(name)
            try store.selectedGuard([t.id])
            try store.removeTunnel(t.id) // refuses while a list uses it
            self.files.removeTunnelFiles(t.id)
            TunnelKeychain.delete(name)
        }
    }

    func renameTunnel(_ name: String, to new: String) async -> String? {
        await attempt {
            let t = try self.stored(name)
            try self.store?.renameTunnel(t.id, to: new)
            TunnelKeychain.rename(name, to: Store.cleanName(new))
        }
    }

    func tunnelLogs(_ name: String) async -> [String] { (try? await Daemon.logs()) ?? [] }

    // MARK: Subscriptions

    /// Removes a subscription and its tunnels; refused while a list uses one of them. Returns the reason when it refuses.
    func removeGroup(_ name: String) async -> String? {
        let e = await attempt {
            guard let store = self.store else { return }
            let sub = try self.subscription(name)
            let ts = try store.tunnels().filter { $0.subscriptionID == sub.id }
            do { try store.selectedGuard(ts.map(\.id)) } catch {
                throw StoreError("The selected tunnel is in this group, and the VPN is on: select a tunnel outside it or turn the VPN off first.")
            }
            try store.removeSubscription(sub.id) // refuses while a list uses one of its tunnels
            for t in ts { self.files.removeTunnelFiles(t.id); TunnelKeychain.delete(t.name) }
            self.files.removeSubscriptionFiles(sub.id)
        }
        if e == nil { forgetCollapsed(name) }
        return e
    }

    /// The saved address (it carries the user's token).
    func groupURL(_ name: String) async -> Result<String, Error> {
        do {
            guard let u = files.subscriptionURL(try subscription(name).id) else { throw StoreError("The saved address of this subscription can't be read.") }
            return .success(u)
        } catch { return .failure(error) }
    }

    /// Renames a subscription and/or replaces its address (checked like a new one, downloaded by the next update).
    /// A new address drops the old usage report and error: they belong to the old one. Returns the reason when it refuses.
    func editGroup(_ name: String, newName: String?, url: String?) async -> String? {
        let e = await attempt {
            guard let store = self.store else { return }
            let sub = try self.subscription(name)
            var newURL: URL?
            if let raw = url?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty { newURL = try Fetch.checkSubscriptionURL(raw) }
            let rename = newName?.trimmingCharacters(in: .whitespaces).nilIfEmpty.flatMap { $0 != sub.name ? $0 : nil }
            let old = self.files.subscriptionURL(sub.id)
            let urlChanged = newURL.map { $0.absoluteString != old } ?? false
            if let newURL, urlChanged { try self.files.writeSubscriptionURL(sub.id, newURL.absoluteString) }
            if let rename {
                do { try store.renameSubscription(sub.id, to: rename) } catch {
                    if urlChanged, let old { try? self.files.writeSubscriptionURL(sub.id, old) } // all or nothing
                    throw error
                }
            }
            if urlChanged {
                self.files.saveUsage(sub.id, nil)
                try? store.setSubscriptionError(sub.id, "")
            }
        }
        if e == nil, let n = newName, !n.isEmpty, n != name { renameCollapsed(name, to: n) }
        return e
    }

    /// Downloads a subscription again. A tunnel the provider still lists keeps its row (so lists and the selection
    /// stay); new ones are added; dropped ones are removed unless a list uses them or they are selected while the VPN is
    /// on, which keeps them. A download that fails or has no usable node changes nothing and is recorded as the error.
    func updateGroup(_ name: String) async {
        guard !updatingGroups.contains(name) else { return }
        updatingGroups.insert(name)
        errors["group:\(name)"] = nil
        groupResults[name] = nil
        defer { updatingGroups.remove(name) }
        do {
            groupResults[name] = Self.describe(try await syncSubscription(name))
        } catch {
            errors["group:\(name)"] = error.localizedDescription
        }
        await changed()
    }

    private func syncSubscription(_ name: String) async throws -> UpdateResult {
        guard let store else { throw StoreError("The settings database isn't open.") }
        let sub = try subscription(name)
        guard let raw = files.subscriptionURL(sub.id) else { throw StoreError("The saved address of this subscription can't be read; set it again.") }
        let u = try Fetch.checkSubscriptionURL(raw)
        func fail(_ message: String) -> StoreError {
            if files.subscriptionURL(sub.id) == raw { try? store.setSubscriptionError(sub.id, message) }
            return StoreError(message)
        }
        let body: String, usage: SubscriptionUsage?
        do { (body, usage) = try await Fetch.subscription(u) } catch { throw fail(error.localizedDescription) }
        let parsed: WireNodes
        do { parsed = try await Daemon.parseLinks(body) } catch let DaemonError.failed(m) {
            throw fail("\(u.host ?? "The server") did not return a subscription: \(m)")
        }
        let (rows, datas) = try nodes(parsed)
        guard !rows.isEmpty else { throw fail("\(u.host ?? "The server") returned no server this app can run; nothing was changed.") }
        // The subscription may have been removed, or its address replaced, during the download.
        guard (try? subscription(name)) != nil else { throw StoreError("No such subscription.") }
        guard files.subscriptionURL(sub.id) == raw else { throw StoreError("The address changed during the download; update again.") }

        let existing = try store.tunnels().filter { $0.subscriptionID == sub.id }
        var res = UpdateResult(added: 0, updated: 0, removed: 0, kept: nil, skipped: parsed.skipped)
        let (match, used) = Self.match(rows, to: existing)
        var sy = Store.Sync()
        var updateData: [Int64: Data] = [:]
        var addData: [Data] = []
        for (i, r) in rows.enumerated() {
            if let j = match[i] {
                let old = existing[j]
                if old.sha != r.sha || old.warning != r.warning || old.remotes != r.remotes {
                    var u = r
                    u.id = old.id
                    u.name = old.name
                    sy.update.append(u)
                    updateData[old.id] = datas[i]
                }
                continue
            }
            sy.add.append(r)
            addData.append(datas[i])
        }
        var kept = 0
        for (j, t) in existing.enumerated() where !used[j] {
            let inUse = !(try store.listsUsing(tunnel: t.id)).isEmpty
            if inUse || (try? store.selectedGuard([t.id])) == nil { kept += 1; continue }
            sy.remove.append(t.id)
        }
        // Changed options are written beside the old file and renamed in after the commit, so a failure never leaves a
        // stored hash over a file that doesn't match it.
        func newFile(_ t: StoreTunnel) -> URL { files.tunnelFile(t).appendingPathExtension("new") }
        let byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        func dropNew() { for id in updateData.keys { if let t = byID[id] { try? FileManager.default.removeItem(at: newFile(t)) } } }
        for (id, data) in updateData {
            guard let t = byID[id] else { continue }
            do { try files.writePrivate(data, to: newFile(t)) } catch { dropNew(); throw error }
        }
        var wrote: [Int64] = []
        do {
            _ = try store.sync(subscription: sub.id, sy) { added in
                for (i, t) in added.enumerated() {
                    wrote.append(t.id)
                    try files.writeTunnelSource(t, addData[i])
                }
            }
        } catch {
            dropNew()
            for id in wrote { files.removeTunnelFiles(id) }
            try? store.setSubscriptionError(sub.id, error.localizedDescription)
            throw error
        }
        for id in updateData.keys {
            guard let t = byID[id] else { continue }
            _ = try? FileManager.default.replaceItemAt(files.tunnelFile(t), withItemAt: newFile(t)) // the hash check refuses it until the next update if this fails
        }
        for id in sy.remove { files.removeTunnelFiles(id); if let t = byID[id] { TunnelKeychain.delete(t.name) } }
        files.saveUsage(sub.id, usage)
        res.added = sy.add.count
        res.updated = sy.update.count
        res.removed = sy.remove.count
        res.kept = kept == 0 ? nil : kept
        return res
    }

    /// Matches each node to the tunnel it already is: by name, then by identical options (a renamed tunnel), then by name
    /// plus the " N" an import adds when a name was taken. Names alone would replace every suffixed or renamed tunnel
    /// on each update.
    static func match(_ rows: [StoreTunnel], to existing: [StoreTunnel]) -> (match: [Int?], used: [Bool]) {
        var match = [Int?](repeating: nil, count: rows.count)
        var used = [Bool](repeating: false, count: existing.count)
        func pass(_ same: (StoreTunnel, StoreTunnel) -> Bool) {
            for (i, r) in rows.enumerated() where match[i] == nil {
                if let j = existing.indices.first(where: { !used[$0] && same(r, existing[$0]) }) { match[i] = j; used[j] = true }
            }
        }
        pass { r, t in Store.cleanName(r.name).caseInsensitiveCompare(t.name) == .orderedSame }
        pass { r, t in r.kind == t.kind && r.sha == t.sha }
        pass { r, t in
            let base = Store.cleanName(r.name).lowercased() + " "
            let name = t.name.lowercased()
            guard name.hasPrefix(base) else { return false }
            let rest = name.dropFirst(base.count)
            return !rest.isEmpty && Int(rest) != nil
        }
        return (match, used)
    }

    static func describe(_ r: UpdateResult) -> String {
        var p: [String] = []
        if r.added > 0 { p.append("\(r.added) added") }
        if r.updated > 0 { p.append("\(r.updated) changed") }
        if r.removed > 0 { p.append("\(r.removed) removed") }
        if let k = r.kept, k > 0 { p.append("\(k) kept, still in use") }
        if let s = r.skipped, !s.isEmpty { p.append("\(s.count) skipped") }
        return p.isEmpty ? "Already up to date" : "Updated: " + p.joined(separator: ", ")
    }

    // MARK: Folded groups

    private static let collapsedKey = "collapsedGroups"

    /// A subscription is open until the user folds it; the choice is kept for the next launch.
    func isCollapsed(_ name: String) -> Bool { collapsedGroups.contains(name) }

    func toggleCollapsed(_ name: String) {
        if collapsedGroups.contains(name) { collapsedGroups.remove(name) } else { collapsedGroups.insert(name) }
        saveCollapsed()
    }

    private func forgetCollapsed(_ name: String) {
        if collapsedGroups.remove(name) != nil { saveCollapsed() }
    }

    private func renameCollapsed(_ old: String, to new: String) {
        if collapsedGroups.remove(old) != nil { collapsedGroups.insert(new); saveCollapsed() }
    }

    private func saveCollapsed() {
        UserDefaults.standard.set(collapsedGroups.sorted(), forKey: Self.collapsedKey)
    }

    static func loadCollapsed() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: collapsedKey) ?? [])
    }

    /// The row's state as the design shows it.
    func designState(_ t: Tunnel) -> Design.TunnelState {
        switch t.state {
        case .disconnected: return .off
        case .connecting, .reconnecting: return .connecting
        case .needsAuth: return .needsAuth
        case .connected: return .connected
        case .ready: return .ready
        case .failed: return .failed(t.error ?? "The tunnel stopped.")
        }
    }
}

extension Tunnel {
    /// "VLESS", "OpenVPN", ...: the protocol as people write it.
    var protocolLabel: String {
        switch protocolName {
        case "openvpn": return "OpenVPN"
        case "vless": return "VLESS"
        case "vmess": return "VMess"
        case "trojan": return "Trojan"
        case "shadowsocks": return "Shadowsocks"
        case "hysteria2": return "Hysteria2"
        case "tuic": return "TUIC"
        case "anytls": return "AnyTLS"
        default: return protocolName
        }
    }
}
