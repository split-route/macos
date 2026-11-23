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

    func snapshot() throws -> Snapshot {
        let vpn = try store.vpn()
        let ks = try store.killSwitch()
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
                w.profile = String(decoding: data, as: UTF8.self)
                if t.needsAuth, let c = credentials(t.name), !(c.username.isEmpty && c.password.isEmpty) {
                    w.username = c.username.nilIfEmpty
                    w.password = c.password.nilIfEmpty
                    sent.insert(t.name)
                }
            } else {
                guard let o = try? JSONDecoder().decode(JSONValue.self, from: data) else {
                    problems[t.coreID] = "The saved options of this tunnel are not valid. Import it again."
                    continue
                }
                w.options = o
            }
            tunnels.append(w)
        }
        let selected = stored.first { $0.id == vpn.selected }.map(\.coreID).flatMap { id in tunnels.contains { $0.id == id } ? id : nil }
        var lists: [WireList] = []
        for l in cfg.lists {
            var w = WireList(name: l.name, action: l.action, tunnel: l.action == .tunnel ? l.tunnel : nil)
            if l.custom {
                w.entries = l.entries
            } else if l.importSource != nil {
                w.entries = try store.importLines(l.name)
            } else if let text = files.releaseText(l.name) {
                w.format = "release"
                w.text = text
            } // a release list not downloaded yet is sent empty: the lists that are downloaded still apply
            lists.append(w)
        }
        self.problems = problems
        self.sentCredentials = sent
        return Snapshot(vpn: vpn.on, listsOn: !cfg.disabled, selected: selected, retry: retry.isEmpty ? nil : retry.sorted(),
                        loadAll: loadAll ? true : nil, killSwitch: ks.on ? true : nil, killSwitchLAN: ks.on && ks.lan ? true : nil,
                        tunnels: tunnels, lists: lists)
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
            let s = try snapshot()
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
