import Foundation

/// Builds the snapshot of what the service should run and sends it. The service keeps nothing: it needs the snapshot
/// after every change here, and again whenever its boot ID changes (it restarted). A tunnel that failed stays failed
/// until a snapshot names it in `retry`, which only a user action adds (retrying bad credentials locks accounts).
@MainActor
final class ServiceLink {
    let store: Store
    let files: AppFiles
    /// The saved credentials for a tunnel by name: this session's, or the Keychain's. Nil when there are none or the
    /// server refused them (they are asked for again, never re-sent).
    var credentials: (String) -> TunnelSecrets? = { _ in nil }

    /// Set while a connectivity test runs: the service loads every tunnel, OpenVPN ones included.
    var loadAll = false
    /// Set while the Mac sleeps with "Disconnect on sleep": the snapshot says the VPN is off, the saved switch isn't touched.
    var suspended = false
    private(set) var bootID: String?
    private(set) var dirty = true
    private var retry = Set<String>()
    /// Tunnels that can't be sent, and why (a saved file that is missing or changed): shown as failed.
    private(set) var problems: [String: String] = [:]
    /// Tunnels whose credentials went out with the last snapshot.
    private(set) var sentCredentials = Set<String>()

    init(store: Store, files: AppFiles) {
        self.store = store
        self.files = files
    }

    func markDirty() { dirty = true }

    /// The user asked: a tunnel (or "*" for all) may be tried again.
    func retry(_ coreIDs: String...) {
        retry.formUnion(coreIDs)
        dirty = true
    }

    /// Notes the service's boot ID. A change means it restarted with no state, so the snapshot goes again.
    func saw(bootID id: String) {
        if bootID != id {
            bootID = id
            dirty = true
        }
    }

    /// What the snapshot needs from the main actor: the retry and load-all asks and the credentials in use.
    private func inputs() throws -> (retry: Set<String>, loadAll: Bool, suspended: Bool, credentials: [String: TunnelSecrets]) {
        var creds: [String: TunnelSecrets] = [:]
        for t in try store.tunnels() where t.isOpenVPN { if let c = credentials(t.name) { creds[t.name] = c } }
        return (retry, loadAll, suspended, creds)
    }

    /// The snapshot, built here (tests, and anything that must be synchronous).
    func snapshot() throws -> Snapshot {
        let i = try inputs()
        let built = try Self.build(store: store, files: files, retry: i.retry, loadAll: i.loadAll, suspended: i.suspended, credentials: i.credentials)
        problems = built.problems
        sentCredentials = built.sent
        return built.snapshot
    }

    /// The snapshot, built off the main actor: it reads the database, every tunnel's saved file and every list (megabytes),
    /// and that must not stall the window.
    private func snapshotAsync() async throws -> Snapshot {
        let i = try inputs()
        let (store, files) = (self.store, self.files)
        let built = try await Task.detached(priority: .userInitiated) {
            try ServiceLink.build(store: store, files: files, retry: i.retry, loadAll: i.loadAll, suspended: i.suspended, credentials: i.credentials)
        }.value
        problems = built.problems
        sentCredentials = built.sent
        return built.snapshot
    }

    struct Built {
        var snapshot: Snapshot
        var problems: [String: String]
        var sent: Set<String>
    }

    nonisolated static func build(store: Store, files: AppFiles, retry: Set<String>, loadAll: Bool, suspended: Bool = false, credentials: [String: TunnelSecrets]) throws -> Built {
        let vpn = try store.vpn()
        let ks = try store.killSwitch()
        let bootstrap = try store.bootstrap()
        let cfg = try store.config()
        let stored = try store.tunnels()
        var problems: [String: String] = [:]
        var sent = Set<String>()
        var tunnels: [WireTunnel] = []
        for t in stored {
            let data: Data
            do { data = try files.tunnelSource(t) } catch {
                problems[t.coreID] = error.localizedDescription
                continue
            }
            var w = WireTunnel(id: t.coreID, name: t.name, protocol: t.kind, needsAuth: t.needsAuth)
            if t.isOpenVPN {
                var profile = String(decoding: data, as: UTF8.self)
                if !t.serverOverride.isEmpty {
                    do { profile = try OvpnProfile.overridingServer(profile, with: t.serverOverride) } catch {
                        problems[t.coreID] = "The server override isn't valid: \(error.localizedDescription)"
                        continue
                    }
                }
                w.profile = profile
                if let c = credentials[t.name] {
                    if t.needsAuth, !(c.username.isEmpty && c.password.isEmpty) {
                        w.username = c.username.nilIfEmpty
                        w.password = c.password.nilIfEmpty
                        sent.insert(t.name)
                    }
                    if t.keyEncrypted, !c.keyPassword.isEmpty {
                        w.keyPassword = c.keyPassword
                        sent.insert(t.name)
                    }
                }
            } else {
                guard let o = try? JSONDecoder().decode(JSONValue.self, from: data) else {
                    problems[t.coreID] = "The saved options of this server are not valid. Import it again."
                    continue
                }
                w.options = o
            }
            tunnels.append(w)
        }
        let selected = stored.first { $0.id == vpn.selected }.map(\.coreID).flatMap { id in tunnels.contains { $0.id == id } ? id : nil }
        var lists: [WireList] = []
        for l in cfg.lists where l.action != .none { // a list with no action isn't sent: the service never sees it
            var w = WireList(name: l.name, action: l.action, tunnel: l.action == .tunnel ? l.tunnel : nil)
            if l.ruleSet {
                // A rule-set kept as it was imported: its bytes go to the engine unchanged.
                guard let bytes = try store.ruleSetData(l.name) else { continue }
                (w.format, w.data) = ("ruleset", bytes)
            } else if l.custom {
                guard !l.rules.isEmpty else { continue } // a rule with no values yet applies nothing
                (w.format, w.rules) = ("rules", l.rules)
            } else if l.importSource != nil {
                w.entries = try store.importLines(l.name)
            } else if let text = files.releaseText(l.name) {
                w.format = "release"
                w.text = text
            } // a release list not downloaded yet is sent empty: the lists that are downloaded still apply
            lists.append(w)
        }
        // Nothing is sent for the default (the selected tunnel): an older snapshot shape stays valid.
        let final = cfg.finalAction == .tunnel && cfg.finalTunnel == nil ? nil : WireFinal(action: cfg.finalAction, tunnel: cfg.finalTunnel)
        let snap = Snapshot(vpn: vpn.on && !suspended, listsOn: !cfg.disabled, selected: selected, final: final, blockQuic: cfg.blockQUIC ? true : nil, blockStun: cfg.blockSTUN ? true : nil, tlsFingerprint: cfg.tlsFingerprint.nilIfEmpty, retry: retry.isEmpty ? nil : retry.sorted(),
                        loadAll: loadAll ? true : nil, bootstrap: bootstrap.nilIfEmpty, killSwitch: ks.on ? true : nil, killSwitchLAN: ks.on && ks.lan ? true : nil,
                        tunnels: tunnels, lists: lists)
        return Built(snapshot: snap, problems: problems, sent: sent)
    }

    /// Sends the snapshot if something changed or the service restarted.
    func pushIfNeeded() async throws {
        guard dirty else { return }
        try await push()
    }

    private var pushing = false

    /// One push at a time, so an older snapshot never lands after a newer one: a change made while one is in flight
    /// is sent when it finishes.
    func push() async throws {
        guard !pushing else { return }
        pushing = true
        defer { pushing = false }
        repeat {
            let sentRetry = retry
            let s = try await snapshotAsync()
            dirty = false
            do {
                try await Daemon.apply(s)
            } catch {
                dirty = true // sent again at the next poll
                throw error
            }
            retry.subtract(sentRetry)
        } while dirty
    }
}
