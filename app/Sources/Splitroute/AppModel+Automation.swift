import AppKit
import Foundation
import UserNotifications

// What the app does by itself: update subscriptions on a schedule, connect when asked to ("Always on"), disconnect when
// the Mac sleeps, and let old test results expire. It runs only while the app does: a quit app updates and connects nothing.

extension AppModel {
    // MARK: Always on, sleep

    /// Hooks the Mac's sleep and wake. Called once.
    func startAutomation() {
        guard !automationStarted else { return }
        automationStarted = true
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.willSleep() }
        }
        nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.didWake() }
        }
    }

    /// With the kill switch on, the service blocks all traffic that isn't the VPN's the moment the VPN is off, so a
    /// disconnect on sleep would leave the Mac with no network on wake. The kill switch wins and sleep keeps the VPN.
    var sleepDisconnectApplies: Bool { Prefs.bool(Prefs.disconnectOnSleep, false) && !killSwitchOn }

    private func willSleep() async {
        guard sleepDisconnectApplies, vpnOn, !sleepSuspended, let link else { return }
        sleepSuspended = true
        link.suspended = true // the saved switch stays on: the snapshot says off until the Mac wakes
        testResults = [:]
        await changed()
        if Prefs.bool(Prefs.showDisconnectMessage, false) { Self.notify("Disconnected", "Splitroute disconnected because your Mac went to sleep.") }
    }

    private func didWake() async {
        if sleepSuspended {
            sleepSuspended = false
            link?.suspended = false
            await changed()
        }
        await connectIfAlwaysOn()
    }

    /// "Always on": a switch that is off comes back on at launch and on wake. It never retries a server that failed
    /// (a wrong password would lock the account): a failed server stays failed until the user acts.
    func connectIfAlwaysOn() async {
        guard Prefs.bool(Prefs.alwaysOn, false), !vpnOn, !tunnels.isEmpty, connError == nil else { return }
        await setVPN(true, automatic: true)
    }

    func setAlwaysOn(_ on: Bool) async {
        UserDefaults.standard.set(on, forKey: Prefs.alwaysOn)
        if on { await connectIfAlwaysOn() }
    }

    /// Asks for permission to post when the message is turned on.
    func setShowDisconnectMessage(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Prefs.showDisconnectMessage)
        if on { UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in } }
    }

    private static func notify(_ title: String, _ body: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    // MARK: The schedule

    /// One pass of the poll, once the service answers and the settings are loaded.
    func runAutomation() async {
        startAutomation()
        if !alwaysOnHandled {
            alwaysOnHandled = true
            await connectIfAlwaysOn()
        }
        await updateDueSubscriptions()
        await locateDueServers()
        await checkForUpdateIfDue()
    }

    var subscriptionInterval: TimeInterval { TimeInterval(Prefs.int(Prefs.subsIntervalHours, 24)) * 3600 }

    /// Updates subscriptions that are due: the first pass after launch when "Update on open" is on, and any whose last
    /// good update is older than the interval when the schedule is on. A failed one waits before it is tried again, so a
    /// dead address isn't fetched every poll. The update itself never drops a server a list or the selection needs.
    private func updateDueSubscriptions() async {
        let onOpen = !subsOpenHandled && Prefs.bool(Prefs.subsUpdateOnOpen, false)
        subsOpenHandled = true
        let auto = Prefs.bool(Prefs.subsAutoUpdate, true)
        guard onOpen || auto, let subs = try? store?.subscriptions(), !subs.isEmpty else { return }
        let every = subscriptionInterval
        let now = Date()
        for s in subs where !updatingGroups.contains(s.name) {
            let overdue = Store.parse(s.updatedAt).map { now.timeIntervalSince($0) >= every } ?? true
            guard onOpen || overdue else { continue }
            if let t = subsAttempt[s.id], now.timeIntervalSince(t) < min(every, 900) { continue }
            subsAttempt[s.id] = now
            await updateGroup(s.name)
        }
    }

    // MARK: App updates

    /// Once at launch, then once a day while the app runs, if the setting is on; a failed check waits an hour. Never says
    /// anything on failure.
    private func checkForUpdateIfDue() async {
        guard Prefs.bool(Prefs.autoCheckUpdates, true), !checkingUpdate else { return }
        if !updateOpenHandled {
            updateOpenHandled = true
            await checkForUpdate(manual: false)
            return
        }
        let last = UserDefaults.standard.object(forKey: "updateCheckedAt") as? Date
        if let last, Date().timeIntervalSince(last) < 24 * 3600 { return }
        if let t = updateAttempt, Date().timeIntervalSince(t) < 3600 { return }
        await checkForUpdate(manual: false)
    }

    /// Asks GitHub for the latest release. A manual check says what it found, including "up to date" and failures.
    func checkForUpdate(manual: Bool) async {
        #if DEBUG
        if ProcessInfo.processInfo.environment["SPLITROUTE_FAKE_UPDATE"] != nil { return } // keep the fake: a real check would clear it
        #endif
        guard !checkingUpdate else { return }
        checkingUpdate = true
        updateAttempt = Date()
        if manual { updateCheckNote = nil }
        defer { checkingUpdate = false }
        do {
            let r = try await AppUpdate.fetchLatest()
            UserDefaults.standard.set(Date(), forKey: "updateCheckedAt")
            let newer = AppUpdate.isNewer(r.version, than: Self.appVersion)
            newerRelease = newer ? r : nil
            rememberRelease(newerRelease)
            if manual { updateCheckNote = newer ? nil : (Self.appVersion == "dev" ? "This is a development build." : "Splitroute is up to date.") }
            // Automatic download, only after an automatic check, and never over what can't be installed anyway.
            if newer, !manual, Prefs.bool(Prefs.autoDownloadUpdates, true), UpdateInstaller.blockedReason() == nil { await downloadUpdate() }
        } catch {
            if manual { updateCheckNote = "Couldn't check: \(error.localizedDescription)" }
        }
    }

    // MARK: Downloading and installing an update

    private static let foundKey = "foundRelease"

    private func rememberRelease(_ r: AppUpdate.Release?) {
        UserDefaults.standard.set(r.flatMap { try? JSONEncoder().encode($0) }, forKey: Self.foundKey)
    }

    /// At launch: what an earlier run found or staged is still true only if it is newer than this version.
    func restoreUpdateState() {
        if let d = UserDefaults.standard.data(forKey: Self.foundKey), let r = try? JSONDecoder().decode(AppUpdate.Release.self, from: d),
           AppUpdate.isNewer(r.version, than: Self.appVersion) { newerRelease = r } else { rememberRelease(nil) }
        stagedUpdate = UpdateInstaller.ready(current: Self.appVersion)
        #if DEBUG
        // SPLITROUTE_FAKE_UPDATE=9.9.9 shows an update as found (and SPLITROUTE_FAKE_STAGED=1 as downloaded), to see the screens.
        if let v = ProcessInfo.processInfo.environment["SPLITROUTE_FAKE_UPDATE"] {
            let base = "https://github.com/split-route/macos/releases/download/v\(v)/\(AppUpdate.zipName(v))"
            newerRelease = AppUpdate.Release(version: v, page: AppUpdate.releasesPage, zip: URL(string: base), zipSHA256: URL(string: base + ".sha256"))
            if ProcessInfo.processInfo.environment["SPLITROUTE_FAKE_STAGED"] != nil { stagedUpdate = v }
        }
        #endif
    }

    /// Turning checks off forgets what was found.
    func forgetRelease() {
        newerRelease = nil
        rememberRelease(nil)
    }

    var updateBlockedReason: String? { UpdateInstaller.blockedReason() }

    func downloadUpdate() async {
        guard let r = newerRelease, stagedUpdate != r.version else { return }
        if case .running? = updateDownload { return }
        updateDownload = .running(nil)
        do {
            _ = try await UpdateInstaller.download(r) { [weak self] p in Task { @MainActor in
                if case .running? = self?.updateDownload { self?.updateDownload = .running(p) }
            } }
            updateDownload = nil
            stagedUpdate = r.version
        } catch {
            updateDownload = .failed(error.localizedDescription)
        }
    }

    /// Starts the swap and quits. The service keeps running through it and the new app restarts it if it is older.
    func installUpdate() {
        guard let v = stagedUpdate else { return }
        do {
            try UpdateInstaller.install(version: v, current: Self.appVersion)
            NSApp.terminate(nil)
        } catch {
            updateDownload = .failed(error.localizedDescription)
        }
    }
}
