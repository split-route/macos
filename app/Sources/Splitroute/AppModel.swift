import AppKit
import Foundation
import Design
import ServiceManagement

/// The app's model: it owns the settings (the `Store`), shows the service's state, and keeps the service running what
/// the settings say by sending it a snapshot (`ServiceLink`). The service only runs the network layer.
@MainActor
final class AppModel: ObservableObject {
    /// active: a tunnel is connected; idle: none is; problem: the last refresh or start failed.
    enum Health { case active, idle, problem, notRunning }

    @Published private(set) var status: Status?
    @Published private(set) var connError: DaemonError?
    @Published private(set) var config: Config?
    @Published var available: [String] = []
    @Published var catalog: [ListInfo] = []
    @Published var actionError: String?
    @Published fileprivate(set) var tunnelList: TunnelList?
    /// Subscriptions being downloaded, the outcome of the last update, and the ones the user folded.
    @Published var updatingGroups: Set<String> = []
    @Published var groupResults: [String: String] = [:]
    @Published var collapsedGroups: Set<String> = AppModel.loadCollapsed()
    /// The last connectivity test by tunnel name, and whether one is running.
    @Published var testResults: [String: TunnelTest] = [:]
    @Published var testing = false
    @Published var busy = false
    /// A newer release of the app than this one, once a check found it; and the state of a check the user asked for.
    @Published var newerRelease: AppUpdate.Release?
    @Published var checkingUpdate = false
    /// The update's download: a fraction or the reason it failed; nil when none is running. `stagedUpdate` is the version
    /// downloaded, checked and waiting to be installed. `confirmingInstall` asks the General page to confirm installing it.
    @Published var updateDownload: Fetch.DownloadState?
    @Published var stagedUpdate: String?
    @Published var confirmingInstall = false
    /// The address the internet sees through the active server, and its country; nil until looked up.
    @Published var exitInfo: ExitInfo?
    @Published var exitLookupFailed = false
    /// What Smart Select last did (or is doing), under its switch on the Servers page.
    @Published var smartNote: String?
    @Published var smartChecking = false
    /// Bumped when the recorded statistics change from outside the page (a reset), so the page reads them again.
    @Published var statsRevision = 0
    /// A section the next settings page should scroll to (a button elsewhere set it); the page clears it.
    @Published var settingsScrollTarget: String?
    @Published var updateCheckNote: String?
    /// Switches whose change is being applied by the service ("vpn", "killswitch", "routing"): a spinner shows beside each.
    @Published var pending: Set<String> = []
    /// What is typed in each page's search field ("servers", "lists"): kept while you visit another page.
    @Published var searches: [String: String] = [:]
    /// Speed through the engine; sampled while the window is open, so Home's chart survives a visit to another page.
    let traffic = TrafficMonitor()
    /// Lists being downloaded now, or whose last download failed; a finished one is removed.
    @Published var downloads: [String: Fetch.DownloadState] = [:]
    /// The last error per row or sheet (keys like "list:Work", "preset", "baseURL"), shown under that row until it next succeeds.
    @Published var errors: [String: String] = [:]
    /// While the settings window is open, the config is re-read on every poll.
    var settingsVisible = false

    let files: AppFiles
    private(set) var store: Store?
    private(set) var link: ServiceLink?
    private(set) var service: ServiceStatus?
    var releaseWarnings: [String] = []
    var lastRelease: Date? = UserDefaults.standard.object(forKey: "releaseFetchedAt") as? Date
    var refreshing = false
    /// The first refresh after launch is the "update on open" one.
    var listsOpenHandled = false
    var subsOpenHandled = false
    var updateOpenHandled = false
    var locating = false
    var statsPrunedDay: Int?
    /// When each subscription was last tried by the schedule, so a failing one isn't hammered.
    var subsAttempt: [Int64: Date] = [:]
    var sleepSuspended = false
    var updateAttempt: Date?
    var exitKey: String?
    // Smart Select (AppModel+SmartSelect.swift)
    var lastProbe = Date.distantPast
    var smartFailures = 0
    var smartPause: Date?
    var smartLastPass = Date.distantPast
    var failedAt: [String: Date] = [:]
    var switchTimes: [Date] = []
    var networkChangedAt: Date?
    var networkSignature: String?
    var networkMonitor: AnyObject?
    var exitTask: Task<Void, Never>?
    var alwaysOnHandled = false
    var automationStarted = false
    private var transports: [String: String?] = [:]
    /// Credentials the user typed without saving them: kept for this run only.
    var sessionSecrets: [String: TunnelSecrets] = [:]
    var tunnelSupplied: [String: Date] = [:]
    /// Tunnels whose saved credentials the server refused: they are asked for again, never re-sent.
    var credentialsRefused: Set<String> = []

    private static let pollInterval: UInt64 = 5_000_000_000
    /// How old the release lists may get before the next refresh (Settings > Connection).
    static var releaseEvery: TimeInterval { TimeInterval(Prefs.int(Prefs.listsIntervalHours, 24)) * 3600 }

    init(files: AppFiles = .standard) {
        self.files = files
        do {
            try LegacyMigration.copyDatabase(to: files)
            let s = try Store(path: files.databasePath)
            let l = ServiceLink(store: s, files: files)
            store = s
            link = l
            l.recordStats = Prefs.bool(Prefs.recordStats, true)
            l.credentials = { [weak self] name in
                guard let self else { return nil }
                if self.credentialsRefused.contains(name) { return nil }
                return self.sessionSecrets[name] ?? TunnelKeychain.load(name)
            }
            reloadLocal()
            restoreUpdateState()
        } catch {
            actionError = "Splitroute's settings can't be opened: \(error.localizedDescription)"
        }
        Task { [weak self] in
            while let self {
                await self.poll()
                try? await Task.sleep(nanoseconds: Self.pollInterval)
            }
        }
    }

    /// One pass: the service's state, then what it needs from the app (its snapshot, credentials, downloads).
    private func poll() async {
        await refreshStatus()
        reloadLocal()
        if connError == nil {
            await migrateLegacySecrets()
            await pushSnapshot()
            await supplyTunnelCredentials()
        }
        if !refreshing { Task { await self.refreshDownloads() } }
        if connError == nil, config != nil { await runAutomation() }
        followExitIP()
        await runSmartSelect()
        await recordTraffic()
        if connError == nil, !settingsVisible { traffic.sampleInBackground() }
        await autoInstallIfNeeded()
    }

    /// active: the VPN is on and its selected tunnel is up; idle: it isn't; problem: the last refresh or start failed.
    var health: Health {
        guard connError == nil, let s = status else { return .notRunning }
        if s.error != nil { return .problem }
        if vpnOn, let t = selectedTunnel, t.state == .connected || t.state == .ready { return .active }
        return .idle
    }

    /// Whether a server can carry traffic now. OpenVPN reports connected; a proxy server has no session of its own and
    /// reports ready when it is the active one. A proxy server that is not the active one is loaded and idle while the
    /// engine runs, and the service reports that as disconnected: it carries a list's traffic all the same.
    func serverIsUp(_ name: String) -> Bool {
        guard let t = tunnels.first(where: { $0.name == name }) else { return false }
        return Self.isUp(t, engineRunning: status?.running == true)
    }

    nonisolated static func isUp(_ t: Tunnel, engineRunning: Bool) -> Bool {
        switch t.state {
        case .connected, .ready: return true
        case .disconnected: return engineRunning && t.protocolName != "openvpn"
        default: return false // connecting, needs sign-in, failed
        }
    }

    /// One sentence on what the connection is doing, plain about the case where it is on but not carrying traffic.
    var summary: String {
        switch health {
        case .notRunning: return connError?.localizedDescription ?? "Connecting…"
        case .problem: return "Problem: \(status?.error ?? "unknown")"
        case .active:
            return "Connected through \(selectedTunnel?.name ?? "the selected server")" + (status?.enabled == false ? ", rules off" : "")
        case .idle:
            guard vpnOn else { return "Disconnected" }
            guard let t = selectedTunnel else { return "No server is selected" }
            let direct = "Traffic uses your normal connection."
            switch t.state {
            case .needsAuth: return "\(t.name) needs your sign-in. \(direct)"
            case .failed: return "\(t.name) failed. \(direct)"
            case .connecting, .reconnecting: return "Connecting through \(t.name)…"
            default: return "\(t.name) isn't ready. \(direct)"
            }
        }
    }

    /// The sidebar's one short line: the tunnel's name while it carries traffic, "Connecting…" while it comes up,
    /// the full sentence for everything else (off, failed, needs sign-in).
    var sidebarStatus: String {
        if health == .active, let t = selectedTunnel { return t.name }
        if vpnOn, let t = selectedTunnel, t.state == .connecting || t.state == .reconnecting { return "Connecting…" }
        return summary
    }

    static let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"

    /// The running service is a different build than this app (after an upgrade the old daemon keeps running until it is restarted).
    var serviceOutdated: Bool {
        if let s = service, (s.apiRev ?? 0) < Daemon.requiredAPIRev { return true } // even a dev build: it would ignore what we send
        guard let v = status?.version, Self.appVersion != "dev" else { return false }
        return v != Self.appVersion
    }

    // MARK: State

    func refreshStatus() async {
        do {
            let s = try await Daemon.status()
            service = s
            link?.saw(bootID: s.bootID)
            if let lost = connError {
                connError = nil
                // An action that failed only because the service was down is moot now.
                if actionError == lost.localizedDescription { actionError = nil }
            }
        } catch let e as DaemonError {
            if connError != e { connError = e }
            service = nil
            if e == .outdated { await restartOutdatedService() }
        } catch {
            connError = .failed(error.localizedDescription)
            service = nil
        }
        rebuildStatus()
    }

    /// After an update the old service binary keeps running and answers in the old format. It understands `restart`;
    /// launchd then starts the updated binary. Once per app version, so a service that won't restart isn't hammered.
    private func restartOutdatedService() async {
        let key = "outdatedRestartTried"
        guard UserDefaults.standard.string(forKey: key) != Self.appVersion else { return }
        UserDefaults.standard.set(Self.appVersion, forKey: key)
        try? await Daemon.restart()
    }

    /// Re-reads the database: the lists and the tunnels, joined with what the service reports.
    func reloadLocal() {
        guard let store else { return }
        do {
            let c = try store.config()
            if c != config { config = c }
            let l = try tunnelListFromStore()
            if l != tunnelList { tunnelList = l }
            pruneSmartLists(existing: Set(try store.tunnels().map(\.id)))
            errors["tunnels"] = nil
        } catch {
            errors["tunnels"] = error.localizedDescription
        }
        rebuildStatus()
    }

    func reloadTunnels() async { reloadLocal() }

    /// The UI's status: the service's counters plus what only the app knows (downloads).
    private func rebuildStatus() {
        guard let s = service, let store else {
            if status != nil { status = nil }
            return
        }
        var imports: [ImportStatus] = []
        var warnings = s.warnings ?? []
        for st in (try? store.imports()) ?? [] {
            imports.append(ImportStatus(name: st.name, url: st.url, entries: st.entries, skipped: st.skipped > 0 ? st.skipped : nil,
                                        fetchedAt: st.fetchedAt.isEmpty ? nil : st.fetchedAt, checkedAt: st.checkedAt.isEmpty ? nil : st.checkedAt,
                                        error: st.lastError.isEmpty ? nil : st.lastError))
            if st.fetchedAt.isEmpty { warnings.append(st.lastError.isEmpty ? "import \(st.name): not downloaded yet" : "import \(st.name): not downloaded: \(st.lastError)") }
            else if !st.lastError.isEmpty { warnings.append("import \(st.name): last download failed (\(st.lastError)); using the earlier copy") }
        }
        warnings += releaseWarnings
        let next = Status(version: s.version, enabled: !(config?.disabled ?? false), running: s.running, connected: s.connected, lists: s.lists,
                          fetched: lastRelease.map(Store.stamp) ?? "", warnings: warnings.isEmpty ? nil : warnings, error: s.error?.nilIfEmpty,
                          imports: imports.isEmpty ? nil : imports)
        if next != status { status = next }
    }

    /// The transport a proxy tunnel uses, read from its options file once per content (cached by hash).
    private func transport(of t: StoreTunnel) -> String? {
        guard !t.isOpenVPN else { return nil }
        if let c = transports[t.sha] { return c }
        var label: String?
        if let data = try? files.tunnelSource(t), let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let kind = (o["transport"] as? [String: Any])?["type"] as? String
            switch kind ?? (["vless", "vmess", "trojan"].contains(t.kind) ? "tcp" : "") {
            case "ws": label = "WebSocket"
            case "httpupgrade": label = "HTTPUpgrade"
            case "grpc": label = "gRPC"
            case "http": label = "HTTP"
            case "quic": label = "QUIC"
            case "tcp": label = "TCP"
            default: label = nil
            }
        }
        transports[t.sha] = .some(label)
        return label
    }

    private func tunnelListFromStore() throws -> TunnelList {
        guard let store, let link else { return TunnelList(tunnels: []) }
        let vpn = try store.vpn()
        let ks = try store.killSwitch()
        let bootstrap = try store.bootstrap()
        let stored = try store.tunnels()
        let subs = try store.subscriptions()
        let groups = Dictionary(uniqueKeysWithValues: subs.map { ($0.id, $0.name) })
        var counts: [Int64: Int] = [:]
        var out: [Tunnel] = []
        var selected: String?
        for t in stored {
            if let g = t.subscriptionID { counts[g, default: 0] += 1 }
            let ws = service?.tunnels[t.coreID]
            var tn = Tunnel(name: t.name, protocolName: t.kind, group: t.subscriptionID.flatMap { groups[$0] }, warning: t.warning.nilIfEmpty, transport: transport(of: t),
                            remotes: t.remotes.isEmpty ? nil : t.remotes, serverOverride: t.serverOverride, needsAuth: t.needsAuth, keyEncrypted: t.keyEncrypted,
                            autoConnect: t.autoConnect, state: ws?.state ?? .disconnected)
            tn.note = t.note
            tn.country = t.country
            if let ws { (tn.error, tn.need, tn.localIP, tn.remoteIP, tn.since) = (ws.error?.nilIfEmpty, ws.need?.nilIfEmpty, ws.localIP?.nilIfEmpty, ws.remoteIP?.nilIfEmpty, ws.since) }
            if let why = link.problems[t.coreID] { tn.state = .failed; tn.error = why }
            if t.id == vpn.selected { selected = t.name }
            out.append(tn)
        }
        let usages = subs.map { s in Subscription(name: s.name, tunnels: counts[s.id] ?? 0, updatedAt: s.updatedAt.nilIfEmpty, error: s.lastError.nilIfEmpty, usage: files.loadUsage(s.id)) }
        return TunnelList(tunnels: out, subscriptions: usages.isEmpty ? nil : usages, vpn: vpn.on, selected: selected, bootstrap: bootstrap,
                          killSwitch: ks.on, killSwitchLAN: ks.lan, killSwitchArmed: service?.killSwitch?.armed, unavailable: service?.unavailable?.nilIfEmpty)
    }

    /// Sends the snapshot when something changed or the service restarted.
    func pushSnapshot() async {
        guard let link else { return }
        do {
            try await link.pushIfNeeded()
            errors["service"] = nil
        } catch let e as DaemonError where e == .notRunning || e == .denied {
            // refreshStatus reports it
        } catch {
            errors["service"] = error.localizedDescription
            actionError = "The service refused the settings: \(error.localizedDescription)"
        }
    }

    /// A change was made: send it now instead of at the next poll, then re-read what the service made of it.
    func changed() async {
        link?.markDirty()
        reloadLocal()
        await pushSnapshot()
        await refreshStatus()
        reloadLocal()
    }

    // MARK: Running one change

    func error(_ key: String) -> String? { errors[key] }

    func clearError(_ key: String) { errors[key] = nil }

    /// Runs a database change; returns its error text, or nil when it worked. The change is sent to the service.
    @discardableResult
    func attempt(_ work: () async throws -> Void) async -> String? {
        busy = true
        defer { busy = false }
        do { try await work() } catch {
            return error.localizedDescription
        }
        await changed()
        return nil
    }

    func edit(_ key: String, _ work: () async throws -> Void) async {
        errors[key] = await attempt(work)
    }

    func perform(_ work: @escaping () async throws -> Void) async {
        busy = true
        defer { busy = false }
        do {
            try await work()
            actionError = nil
        } catch {
            actionError = error.localizedDescription
        }
        await refreshStatus()
    }

    // MARK: Service install (SMAppService: Login Items, approved once by the user)

    /// The routing service, bundled at Contents/Library/LaunchDaemons (build-app.sh).
    private static let daemon = SMAppService.daemon(plistName: "io.github.aliraghebi.splitroute.plist")
    /// Where `splitroute install` (and app versions before 0.9) put the service.
    private static let legacyPlist = "/Library/LaunchDaemons/io.github.aliraghebi.splitroute.plist"
    private static let promptedKey = "autoInstallPromptedVersion"
    /// What the one automatic try is counted by: the app version, and the API revision it needs, so a dev build (whose
    /// version is always "dev") still restarts an old service once when the API changes.
    private static var upgradeMarker: String { "\(appVersion)/api\(Daemon.requiredAPIRev)" }
    private static let uninstalledKey = "serviceUninstalledByUser"

    private var legacyInstalled: Bool { FileManager.default.fileExists(atPath: Self.legacyPlist) }

    /// The daemon binary shipped inside the app bundle (runs the one-time migration).
    private var daemonPath: String? { Bundle.main.path(forResource: "splitroute", ofType: nil) }

    /// Registered, but macOS waits for the user to allow it in Login Items.
    var serviceNeedsApproval: Bool { Self.daemon.status == .requiresApproval }

    /// Registered and allowed, yet not answering: launchd can't start it.
    var serviceNotStarting: Bool { Self.daemon.status == .enabled && connError == .notRunning }

    /// The app still has the quarantine flag of a browser download (a DMG copied
    /// by hand; the Homebrew cask removes it). launchd then refuses to start the
    /// service binary, which isn't notarized.
    var appQuarantined: Bool { getxattr(Bundle.main.bundlePath, "com.apple.quarantine", nil, 0, 0, 0) >= 0 }

    func openLoginItems() { SMAppService.openSystemSettingsLoginItems() }

    func installService() async {
        let fresh = Self.daemon.status != .enabled && !legacyInstalled
        UserDefaults.standard.removeObject(forKey: Self.uninstalledKey)
        if legacyInstalled {
            // Same label: the old launchd job must go before the app's can load.
            // Its stop runs `down`; the new service re-applies the routes.
            await runPrivileged("uninstall", prompt: "Splitroute needs your password once to move its routing service to Login Items.")
            guard !legacyInstalled else { return } // canceled or failed; runPrivileged set the error
        }
        busy = true
        defer { busy = false }
        do {
            try Self.daemon.register()
        } catch where Self.daemon.status == .requiresApproval {
            // The first registration "fails" until the user allows it.
        } catch {
            actionError = "Couldn't register the service: \(error.localizedDescription)"
            return
        }
        actionError = nil
        if Self.daemon.status == .requiresApproval { openLoginItems() }
        try? await Task.sleep(nanoseconds: 1_500_000_000) // the service opens its socket
        await refreshStatus()
        // On a first install, open at login so the routing state stays visible
        // after a reboot. Not on reinstalls: the user may have turned it off.
        if fresh, connError == nil, !launchAtLogin { setLaunchAtLogin(true) }
    }

    /// Runs the app's copy of the service binary: after an app update the
    /// service keeps running the old one until it restarts. The service exits
    /// keeping its routes and launchd starts it again (KeepAlive). A service
    /// still installed the old way is moved to Login Items instead.
    func restartService() async {
        guard Self.daemon.status == .enabled, !legacyInstalled else { return await installService() }
        await perform { try await Daemon.restart() }
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        await refreshStatus()
    }

    func uninstallService() async {
        UserDefaults.standard.set(true, forKey: Self.uninstalledKey)
        // Its rules and boot marker outlive the service: turn the kill switch off first, or the network stays blocked.
        if killSwitchOn { await setKillSwitch(on: false) }
        if legacyInstalled {
            await runPrivileged("uninstall", prompt: "Splitroute needs your password to remove its routing service.")
            return
        }
        // launchd stops the job; its SIGTERM handler removes the routes.
        await perform { try await Self.daemon.unregister() }
    }

    /// Without a click: installs on first launch when the service was never
    /// installed, and restarts it after an app upgrade while the old binary runs.
    /// At most once per app version, so a canceled prompt or a failing restart
    /// doesn't repeat every poll; a service the user removed stays removed.
    private func autoInstallIfNeeded() async {
        let d = UserDefaults.standard
        guard !busy, d.string(forKey: Self.promptedKey) != Self.upgradeMarker else { return }
        let st = Self.daemon.status
        let neverInstalled = connError == .notRunning
            && st != .enabled && st != .requiresApproval
            && !legacyInstalled
            && !d.bool(forKey: Self.uninstalledKey)
        guard neverInstalled || serviceOutdated else { return }
        d.set(Self.upgradeMarker, forKey: Self.promptedKey)
        if neverInstalled { await installService() } else { await restartService() }
    }

    private func runPrivileged(_ command: String, prompt: String) async {
        guard let exe = daemonPath else {
            actionError = "The splitroute binary is missing from the app bundle."
            return
        }
        busy = true
        defer { busy = false }
        // Only the move from the old launchd install (and removing one) needs root
        // this way; SMAppService handles the rest without a password.
        let shell = "'\(exe.replacingOccurrences(of: "'", with: "'\\''"))' \(command)"
        let script = "do shell script \"\(shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\" with prompt \"\(prompt)\" with administrator privileges"
        let result: (Int32, String) = await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", script]
            let err = Pipe()
            p.standardError = err
            p.standardOutput = Pipe()
            do { try p.run() } catch { return (-1, error.localizedDescription) }
            p.waitUntilExit()
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return (p.terminationStatus, msg)
        }.value
        if result.0 != 0 && !result.1.contains("User canceled") {
            actionError = result.1.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            actionError = nil
        }
        // The service needs a moment to open its socket.
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        await refreshStatus()
        if command == "install", connError == nil { await loadSettings() }
        if command == "uninstall" { config = nil }
    }

    // MARK: Launch at login

    /// Cached: asking SMAppService is an IPC to the system, too slow to do on every redraw of Settings. Read again when
    /// the window opens and after a change.
    @Published private(set) var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled

    func refreshLaunchAtLogin() { launchAtLogin = SMAppService.mainApp.status == .enabled }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            actionError = nil
        } catch {
            actionError = "Launch at login: \(error.localizedDescription)"
        }
        refreshLaunchAtLogin()
    }
}

/// The address and country the internet sees through the active server (looked up by the service, through it).
struct ExitInfo: Equatable {
    var ip: String
    var country: String
    var code: String? // two letters; the flag is drawn from it, never taken from the answer
}
