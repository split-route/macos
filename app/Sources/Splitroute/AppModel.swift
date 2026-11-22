import AppKit
import Foundation
import Design
import ServiceManagement

@MainActor
final class AppModel: ObservableObject {
    /// active: a tunnel is connected; idle: none is; problem: the last refresh or start failed.
    enum Health { case active, idle, problem, notRunning }

    @Published private(set) var status: Status?
    @Published private(set) var connError: DaemonError?
    @Published private(set) var config: Config?
    @Published private(set) var presets: [Preset] = []
    @Published private(set) var available: [String] = []
    @Published private(set) var catalog: [ListInfo] = []
    @Published var actionError: String?
    @Published fileprivate(set) var tunnelList: TunnelList?
    /// Subscriptions being downloaded, the outcome of the last update, and the ones the user folded.
    @Published private(set) var updatingGroups: Set<String> = []
    @Published private(set) var groupResults: [String: String] = [:]
    @Published private(set) var collapsedGroups: Set<String> = AppModel.loadCollapsed()
    fileprivate var tunnelSupplied: [String: Date] = [:]
    /// Tunnels whose saved credentials the server refused: they are asked for again, never re-sent.
    fileprivate var credentialsRefused: Set<String> = []
    @Published private(set) var busy = false
    /// The daemon's last error per row or sheet (keys like "list:Work",
    /// "preset", "baseURL"), shown under that row until it next succeeds.
    @Published private(set) var errors: [String: String] = [:]
    /// While the settings window is open, the config is re-read on every poll,
    /// so edits made with the CLI show up.
    var settingsVisible = false

    private static let pollInterval: UInt64 = 5_000_000_000

    init() {
        Task { [weak self] in
            while let self {
                await self.refreshStatus()
                if self.settingsVisible, self.connError == nil, !self.busy { await self.reloadConfig() }
                if self.connError == nil {
                    await self.reloadTunnels()
                    await self.supplyTunnelCredentials()
                }
                await self.autoInstallIfNeeded()
                try? await Task.sleep(nanoseconds: Self.pollInterval)
            }
        }
    }

    /// active: the VPN is on and its selected tunnel is up; idle: it isn't; problem: the last refresh or start failed.
    var health: Health {
        guard connError == nil, let s = status else { return .notRunning }
        if s.error != nil { return .problem }
        if vpnOn, let t = selectedTunnel, t.state == .connected || t.state == .ready { return .active }
        return .idle
    }

    /// One sentence on what the VPN is doing, plain about the case where it is on but not carrying traffic.
    var summary: String {
        switch health {
        case .notRunning: return connError?.localizedDescription ?? "Connecting…"
        case .problem: return "Problem: \(status?.error ?? "unknown")"
        case .active:
            return "On, through \(selectedTunnel?.name ?? "the selected tunnel")" + (status?.enabled == false ? ", lists off" : "")
        case .idle:
            guard vpnOn else { return "The VPN is off" }
            guard let t = selectedTunnel else { return "On, but no tunnel is selected" }
            let direct = "Traffic uses your normal connection."
            switch t.state {
            case .needsAuth: return "On, but \(t.name) needs your sign-in. \(direct)"
            case .failed: return "On, but \(t.name) failed. \(direct)"
            case .connecting, .reconnecting: return "Connecting through \(t.name)…"
            default: return "On, but \(t.name) isn't ready. \(direct)"
            }
        }
    }

    static let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"

    /// The running service is a different build than this app (after an upgrade
    /// the old daemon keeps running until it is reinstalled).
    var serviceOutdated: Bool {
        guard let v = status?.version, Self.appVersion != "dev" else { return false }
        return v != Self.appVersion
    }

    func refreshStatus() async {
        do {
            let s = try await Daemon.status()
            if s != status { status = s }
            if let lost = connError {
                connError = nil
                // An action that failed only because the service was down (say,
                // turning routing on while it was starting) is moot now.
                if actionError == lost.localizedDescription { actionError = nil }
            }
        } catch let e as DaemonError {
            if connError != e { connError = e }
            status = nil
        } catch {
            connError = .failed(error.localizedDescription)
        }
    }

    /// Loads what the settings window needs; the release list names need the network.
    func loadSettings() async {
        await perform {
            self.config = try await Daemon.config()
            self.presets = try await Daemon.presets()
        }
        if let l = try? await Daemon.lists() {
            available = l.names
            catalog = l.catalog
        }
    }

    func setEnabled(_ on: Bool) async {
        await perform { self.config = try await Daemon.setEnabled(on) }
    }

    private func reloadConfig() async {
        if let c = try? await Daemon.config(), c != config { config = c }
    }

    // MARK: Per-list edits. Each is one daemon transaction on its current config.

    /// tunnel names the tunnel for the tunnel action; nil means the default tunnel.
    func setAction(_ name: String, _ a: Action, tunnel: String? = nil) async {
        await edit("list:\(name)") { try await Daemon.edit("list_set_action", name: name, action: a, tunnel: tunnel) }
    }

    func removeList(_ name: String) async {
        await edit("list:\(name)") { try await Daemon.edit("list_remove", name: name) }
    }

    func moveList(_ name: String, to position: Int) async {
        await edit("list:\(name)") { try await Daemon.edit("list_move", name: name, position: position) }
    }

    func enableRelease(_ name: String, _ a: Action = .direct) async {
        await edit("lists") { try await Daemon.edit("list_enable", name: name, action: a) }
    }

    func refreshImport(_ name: String) async {
        await edit("list:\(name)") {
            try await Daemon.refreshImport(name)
            return nil
        }
    }

    /// The release list's title and description; nil for custom lists, imports and
    /// release lists the service hasn't described (it may be older).
    func info(_ name: String) -> ListInfo? { catalog.first { $0.name == name } }

    /// Creates a custom list from a file's text. Returns the entry counts, or the
    /// daemon's error.
    func createFromFile(name: String, action: Action, text: String) async -> (edit: EntryEdit?, error: String?) {
        var counts: EntryEdit?
        let e = await attempt {
            let r = try await Daemon.createFromText(name: name, action: action, text: text)
            counts = r.edit
            return r.config
        }
        // A service older than this app ignores "text" and creates an empty list
        // with no counts: undo that instead of reporting success.
        if e == nil, counts == nil {
            await removeList(name)
            return (nil, "The service is older than this app and can't import files. Update it (Advanced → Reinstall service), then try again.")
        }
        return (counts, e)
    }

    /// Returns the daemon's error, or nil when the import was added.
    func importList(name: String, url: String, action: Action) async -> String? {
        await attempt { try await Daemon.edit("list_import", name: name, action: action, url: url) }
    }

    /// Saves a custom list from the editor: creates it (original nil) or applies
    /// the rename, action and entries that changed. These are separate daemon
    /// edits, so on an error the ones before it are kept; the returned name is
    /// the list's name in the daemon afterwards (nil if it wasn't created).
    func saveCustom(original: String?, name: String, action: Action, entries: [String]) async -> (name: String?, error: String?) {
        var current = original
        let old = original.flatMap { o in config?.lists.first { $0.name == o } }
        if current == nil {
            if let e = await attempt({ try await Daemon.edit("list_create", name: name, action: action) }) { return (nil, e) }
            current = name
        }
        if let c = current, c != name {
            if let e = await attempt({ try await Daemon.edit("list_rename", name: c, newName: name) }) { return (c, e) }
            current = name
        }
        if let old, old.action != action {
            if let e = await attempt({ try await Daemon.edit("list_set_action", name: name, action: action) }) { return (current, e) }
        }
        if old?.entries ?? [] != entries {
            if let e = await attempt({ try await Daemon.edit("entries_set", name: name, entries: entries) }) { return (current, e) }
        }
        return (current, nil)
    }

    func applyPreset(_ id: String) async {
        await edit("preset") { try await Daemon.applyPreset(id) }
    }

    /// Sets the release URL (nil: the default). The daemon has no per-field
    /// command for it, so this re-reads the config right before writing it; an
    /// edit landing between the two would still be overwritten.
    func setBaseURL(_ url: String?) async {
        await edit("baseURL") {
            var c = try await Daemon.config()
            c.baseURL = url
            return try await Daemon.setConfig(c)
        }
    }

    func error(_ key: String) -> String? { errors[key] }

    func clearError(_ key: String) { errors[key] = nil }

    private func edit(_ key: String, _ work: @escaping () async throws -> Config?) async {
        errors[key] = await attempt(work)
    }

    /// Runs one daemon call; on success stores the config it returned.
    private func attempt(_ work: @escaping () async throws -> Config?) async -> String? {
        busy = true
        var msg: String?
        do {
            if let c = try await work() { config = c }
        } catch {
            msg = error.localizedDescription
        }
        busy = false
        await refreshStatus()
        return msg
    }

    private func perform(_ work: @escaping () async throws -> Void) async {
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
        guard !busy, d.string(forKey: Self.promptedKey) != Self.appVersion else { return }
        let st = Self.daemon.status
        let neverInstalled = connError == .notRunning
            && st != .enabled && st != .requiresApproval
            && !legacyInstalled
            && !d.bool(forKey: Self.uninstalledKey)
        guard neverInstalled || serviceOutdated else { return }
        d.set(Self.appVersion, forKey: Self.promptedKey)
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

    var launchAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            actionError = nil
        } catch {
            actionError = "Launch at login: \(error.localizedDescription)"
        }
        objectWillChange.send()
    }
}


// MARK: Tunnels (OpenVPN). Credentials live in the Keychain; the service only gets them to connect.

extension TunnelSecrets {
    var isEmpty: Bool { username.isEmpty && password.isEmpty && keyPassword.isEmpty }
}

extension AppModel {
    var tunnels: [Tunnel] { tunnelList?.tunnels ?? [] }

    func reloadTunnels() async {
        do {
            let l = try await Daemon.tunnels()
            if l != tunnelList { tunnelList = l }
            errors["tunnels"] = nil
        } catch {
            errors["tunnels"] = error.localizedDescription
        }
    }

    /// A tunnel waiting for credentials that the Keychain has: send them, without asking.
    /// At most once a minute per tunnel, so a denied Keychain prompt or a service that doesn't take them isn't hammered.
    func supplyTunnelCredentials() async {
        for t in tunnels where t.state == .needsAuth {
            // Before the Keychain read: a denied access prompt must not come back on every poll.
            if credentialsRefused.contains(t.name) { continue } // the server refused them: ask, don't re-send
            if let last = tunnelSupplied[t.name], Date().timeIntervalSince(last) < 60 { continue }
            tunnelSupplied[t.name] = Date()
            guard let s = TunnelKeychain.load(t.name) else { continue }
            try? await Daemon.tunnelCredentials(t.name, secrets: s)
        }
    }

    /// Connecting needs a prompt when the profile wants credentials and none are saved.
    func needsCredentialPrompt(_ t: Tunnel) -> Bool {
        (t.needsAuth || t.keyEncrypted) && TunnelKeychain.load(t.name) == nil
    }

    func connectTunnel(_ t: Tunnel, secrets: TunnelSecrets? = nil, remember: Bool = false) async {
        if let secrets, remember { TunnelKeychain.save(t.name, secrets) }
        if secrets != nil { credentialsRefused.remove(t.name) } // new credentials from the user
        errors["tunnel:\(t.name)"] = nil
        do {
            try await Daemon.tunnelConnect(t.name, secrets: secrets ?? TunnelKeychain.load(t.name))
        } catch {
            errors["tunnel:\(t.name)"] = error.localizedDescription
            return
        }
        await followTunnel(t.name)
    }

    /// Re-reads the tunnel every second until it settles, so the switch reflects the progress.
    private func followTunnel(_ name: String) async {
        for _ in 0..<20 {
            await reloadTunnels()
            if let t = tunnels.first(where: { $0.name == name }), [.connected, .failed, .needsAuth, .disconnected].contains(t.state) { return }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    /// Imports share links or a subscription. `url` is kept as a subscription (named `name`, or by
    /// its host); `text` is pasted links, a subscription body or one address. Returns the service's
    /// result, or its error.
    func addTunnels(text: String?, url: String?, name: String?) async -> Result<AddResult, Error> {
        do {
            let r = try await Daemon.tunnelsAdd(text: text, url: url, name: name)
            await reloadTunnels()
            return .success(r)
        } catch {
            return .failure(error)
        }
    }

    /// Removes a subscription and its tunnels; the service refuses while a list uses one of them.
    /// Returns the service's reason when it refuses.
    func removeGroup(_ name: String) async -> String? {
        defer { Task { await reloadTunnels() } }
        do {
            try await Daemon.tunnelGroupRemove(name)
            forgetCollapsed(name)
            return nil
        } catch { return error.localizedDescription }
    }

    /// Downloads a subscription again. The outcome shows under its name until the next update.
    func updateGroup(_ name: String) async {
        guard !updatingGroups.contains(name) else { return }
        updatingGroups.insert(name)
        errors["group:\(name)"] = nil
        groupResults[name] = nil
        do {
            groupResults[name] = Self.describe(try await Daemon.tunnelGroupUpdate(name))
        } catch {
            errors["group:\(name)"] = error.localizedDescription
        }
        updatingGroups.remove(name)
        await reloadTunnels()
    }

    private static func describe(_ r: UpdateResult) -> String {
        var p: [String] = []
        if r.added > 0 { p.append("\(r.added) added") }
        if r.updated > 0 { p.append("\(r.updated) changed") }
        if r.removed > 0 { p.append("\(r.removed) removed") }
        if let k = r.kept, k > 0 { p.append("\(k) kept, still in use") }
        if let s = r.skipped, !s.isEmpty { p.append("\(s.count) skipped") }
        return p.isEmpty ? "Already up to date" : "Updated: " + p.joined(separator: ", ")
    }

    func groupURL(_ name: String) async -> Result<String, Error> {
        do { return .success(try await Daemon.tunnelGroupURL(name)) } catch { return .failure(error) }
    }

    /// Renames a subscription and/or replaces its address. Returns the service's reason when it refuses.
    func editGroup(_ name: String, newName: String?, url: String?) async -> String? {
        do {
            try await Daemon.tunnelGroupEdit(name, newName: newName, url: url)
            if let n = newName, !n.isEmpty, n != name { renameCollapsed(name, to: n) }
            await reloadTunnels()
            return nil
        } catch { return error.localizedDescription }
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

    func removeTunnel(_ name: String) async {
        await tunnelCall(name) {
            try await Daemon.tunnelRemove(name)
            TunnelKeychain.delete(name)
        }
    }

    func renameTunnel(_ name: String, to new: String) async -> String? {
        do {
            try await Daemon.tunnelRename(name, to: new)
            TunnelKeychain.rename(name, to: new)
            await reloadTunnels()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func tunnelLogs(_ name: String) async -> [String] { (try? await Daemon.tunnelLogs(name)) ?? [] }

    /// Returns the daemon's error, or nil when the tunnel was added.
    func importTunnel(name: String, text: String, secrets: TunnelSecrets?) async -> String? {
        do {
            try await Daemon.tunnelImport(name: name, text: text)
            if let secrets, !secrets.isEmpty { TunnelKeychain.save(name, secrets) }
            await reloadTunnels()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func checkTunnel(text: String) async -> Result<TunnelCheck, Error> {
        do { return .success(try await Daemon.tunnelCheck(text: text)) } catch { return .failure(error) }
    }

    private func tunnelCall(_ name: String, _ work: () async throws -> Void) async {
        errors["tunnel:\(name)"] = nil
        do { try await work() } catch { errors["tunnel:\(name)"] = error.localizedDescription }
        await reloadTunnels()
    }
}

// MARK: The VPN switch and the selected tunnel

extension AppModel {
    /// Whether the user has the VPN on (the service's answer).
    var vpnOn: Bool { tunnelList?.vpn ?? false }

    /// The tunnel that carries all traffic no list names.
    var selectedTunnel: Tunnel? {
        guard let n = tunnelList?.selected else { return nil }
        return tunnels.first { $0.name == n }
    }

    /// Turns the VPN on or off. The service picks the first tunnel if none is selected.
    func setVPN(_ on: Bool) async {
        errors["vpn"] = nil
        do { try await Daemon.vpnSet(on) } catch { errors["vpn"] = error.localizedDescription }
        await reloadTunnels()
        await refreshStatus()
    }

    /// Chooses the tunnel for all traffic no list names. While the VPN is on, the engine
    /// switches to it without restarting. Returns true when the credentials sheet should open:
    /// the tunnel needs credentials the Keychain doesn't have, or the server refused the saved ones
    /// (those are never sent again without asking).
    func selectTunnel(_ t: Tunnel) async -> Bool {
        errors["tunnel:\(t.name)"] = nil
        let refused = t.state == .failed && Self.credentialsRefused(t.error)
        if refused { credentialsRefused.insert(t.name) }
        do { try await Daemon.tunnelSelect(t.name) } catch {
            errors["tunnel:\(t.name)"] = error.localizedDescription
            return false
        }
        await reloadTunnels()
        await refreshStatus()
        guard vpnOn else { return false }
        return refused || (tunnels.first { $0.name == t.name }.map { $0.state == .needsAuth && needsCredentialPrompt($0) } ?? false)
    }

    static func credentialsRefused(_ error: String?) -> Bool {
        guard let e = error else { return false }
        return e.contains("username or password") || e.contains("key password")
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
