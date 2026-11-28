import AppKit
import Design
import SwiftUI

/// Settings > Application: theme, language, startup, the app's version and updates, and the system service.
struct ApplicationSettingsPage: View {
    @EnvironmentObject private var model: AppModel
    @State private var confirmUninstall = false
    @AppStorage("quitAction") private var quitAction = "" // read by AppDelegate.quit
    @AppStorage(Prefs.autoCheckUpdates) private var autoCheck = true
    @AppStorage(Prefs.autoDownloadUpdates) private var autoDownload = true

    @AppStorage(Theme.key) private var theme = Theme.system.rawValue
    private static let quitLabels = ["": "Ask", "turnOff": "Disconnect", "keep": "Keep it on"]

    var body: some View {
        SettingsPage("Application") {
            if model.status == nil { ServiceUnavailable() }
            warnings
            appearance
            startup
            service
            about
        }
        .confirmationDialog("Install Splitroute \(model.stagedUpdate ?? "")?", isPresented: $model.confirmingInstall) {
            Button("Install and Restart") { model.installUpdate() }
        } message: {
            Text("Splitroute quits and opens again. The connection stays on, but may drop for a few seconds while the service restarts."
                 + (model.killSwitchOn && model.vpnOn ? " The kill switch is on, so the network stays blocked until the new version has reconnected." : ""))
        }
        .confirmationDialog("Uninstall the Splitroute service?", isPresented: $confirmUninstall) {
            Button("Uninstall", role: .destructive) { Task { await model.uninstallService() } }
        } message: {
            Text("Servers disconnect and routing stops until you install the service again.")
        }
    }

    private func toggle(_ title: String, isOn: Binding<Bool>) -> some View { settingsSwitch(title, isOn: isOn) }

    /// The newer version: where it is (not downloaded, downloading with its percentage, ready), and the button for the next step.
    private func newVersionRow(_ r: AppUpdate.Release) -> some View {
        let blocked = model.updateBlockedReason
        let ready = model.stagedUpdate == r.version
        var detail = "Not downloaded yet."
        var detailColor = Palette.inkSecondary.color
        if case .failed(let why)? = model.updateDownload { (detail, detailColor) = (why, Palette.danger.color) }
        else if case .running(let p)? = model.updateDownload { detail = "Downloading… " + (p.map { "\(Int($0 * 100))%" } ?? "") }
        else if ready { detail = "Downloaded and verified." }
        else if let blocked { detail = blocked } else if r.zip == nil { detail = "This release has no app archive to download." }
        return HStack(alignment: .center, spacing: Space.l) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Circle().fill(Palette.success.color).frame(width: 8, height: 8).accessibilityHidden(true)
                    Text(ready ? "\(r.version) is ready to install" : "\(r.version) is available").font(TypeScale.bodyStrong).foregroundStyle(Palette.success.color)
                }
                Text(detail).font(TypeScale.secondary).foregroundStyle(detailColor).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Space.m)
            // One height for every state (a button, a progress bar): the row doesn't jump when the download starts.
            HStack(spacing: Space.m) {
                if case .running(let p)? = model.updateDownload {
                    HStack(spacing: Space.s) {
                        if let p { ProgressView(value: p).frame(width: 120) } else { ProgressView().controlSize(.small) }
                        Text(p.map { "\(Int($0 * 100))%" } ?? "").font(TypeScale.secondary).monospacedDigit().frame(width: 36, alignment: .trailing)
                    }
                } else {
                    if blocked != nil || r.zip == nil {
                        // Nothing to download here: the release page is the way to update.
                        Link("Open release page", destination: r.page).font(TypeScale.bodyStrong)
                    } else if ready {
                        Button("Install…") { model.confirmingInstall = true }.buttonStyle(SolidButtonStyle())
                    } else {
                        Button("Download") { Task { await model.downloadUpdate() } }.buttonStyle(SolidButtonStyle())
                    }
                }
            }
            .frame(height: 40)
        }
        .padding(.vertical, Space.m).padding(.horizontal, Space.l)
    }

    /// What the last check came to, beside its button: green for up to date, red for a failure.
    private var checkResult: (text: String, color: Color)? {
        guard let n = model.updateCheckNote else { return nil }
        if n.hasPrefix("Couldn't") { return (n, Palette.danger.color) }
        return (n, n == "Splitroute is up to date." ? Palette.success.color : Palette.inkSecondary.color)
    }

    // MARK: Warnings

    /// What the service wants you to know, such as a list blocked because its server isn't connected. Only when there is some.
    @ViewBuilder private var warnings: some View {
        let list = model.status?.warnings ?? []
        if !list.isEmpty {
            SettingsSection("Warnings") {
                VStack(alignment: .leading, spacing: Space.s) {
                    ForEach(list, id: \.self) { NoteLine(.warning, $0) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Space.l)
            }
        }
    }

    // MARK: Appearance

    @ViewBuilder private var appearance: some View {
        SettingsSection("Appearance") {
            FormRow("Theme", detail: "Light, dark or system.") {
                SelectMenu(title: (Theme(rawValue: theme) ?? .system).title, options: Theme.allCases, label: { $0.title },
                           selected: Theme(rawValue: theme) ?? .system) { t in
                    theme = t.rawValue
                    t.apply()
                }
            }
            Hairline()
            FormRow("Language") {
                Text("English").font(TypeScale.body).foregroundStyle(Palette.inkSecondary.color)
            }
        }
    }

    // MARK: Startup

    @ViewBuilder private var startup: some View {
        SettingsSection("Startup") {
            FormRow("Open at login", detail: "Show the menu bar icon after you log in.") {
                toggle("Open at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
            }
            Hairline()
            FormRow("When quitting while connected", detail: "Keep it on leaves the service running.") {
                SelectMenu(title: Self.quitLabels[quitAction] ?? "Ask", options: ["", "turnOff", "keep"],
                           label: { Self.quitLabels[$0] ?? $0 }, selected: quitAction) { quitAction = $0 }
            }
            Hairline()
            FormRow("Global shortcut", detail: "Connect or disconnect from any app.") { ShortcutRecorder() }
        }
    }

    // MARK: System service

    @ViewBuilder private var service: some View {
        SettingsSection("System service") {
            if model.serviceOutdated, let v = model.status?.version {
                FormRow("Update service", detail: "Service \(v), app \(AppModel.appVersion).") {
                    Button("Update") { Task { await model.restartService() } }
                        .buttonStyle(OutlineButtonStyle()).disabled(model.busy)
                }
                Hairline()
            }
            FormRow("Restart service",
                    detail: "The connection comes back by itself. To turn the service off, use System Settings > Login Items.",
                    error: model.actionError) {
                Button("Restart") { Task { await model.restartService() } }
                    .buttonStyle(OutlineButtonStyle()).disabled(model.busy)
            }
            Hairline()
            FormRow("Uninstall service", detail: "Stops the service. Settings are kept.") {
                Button("Uninstall…", role: .destructive) { confirmUninstall = true }
                    .buttonStyle(OutlineButtonStyle()).disabled(model.busy || model.connError == .notRunning)
            }
        }
    }

    // MARK: About

    @ViewBuilder private var about: some View {
        SettingsSection("About") {
            FormRow("Version", detail: AppModel.appVersion + (model.status.map { $0.version != AppModel.appVersion ? ", service \($0.version)" : "" } ?? "")) {
                HStack(spacing: Space.m) {
                    if let r = checkResult {
                        Text(r.text).font(TypeScale.secondary).foregroundStyle(r.color).lineLimit(2).multilineTextAlignment(.trailing)
                            .frame(maxWidth: 280, alignment: .trailing).help(r.text)
                    }
                    if model.checkingUpdate { ProgressView().controlSize(.small) }
                    Button("Check for updates") { Task { await model.checkForUpdate(manual: true) } }
                        .buttonStyle(OutlineButtonStyle()).disabled(model.checkingUpdate)
                }
            }
            if let r = model.newerRelease {
                Hairline()
                newVersionRow(r)
            }
            Hairline()
            FormRow("Country data", detail: "Server flags use IP to Country Lite by DB-IP.com (CC BY 4.0).") {
                Link("db-ip.com", destination: URL(string: "https://db-ip.com")!).font(TypeScale.bodyStrong)
            }
            Hairline()
            FormRow("Check for updates automatically", detail: "Asks GitHub once a day.") {
                settingsSwitch("Check for updates automatically", isOn: Binding(get: { autoCheck }, set: { on in
                    autoCheck = on
                    if on { Task { await model.checkForUpdate(manual: false) } } else { model.forgetRelease() }
                }))
            }
            Hairline()
            FormRow("Download updates automatically", detail: "Have new versions ready to install. Nothing installs without you.") {
                settingsSwitch("Download updates automatically", isOn: $autoDownload).disabled(!autoCheck)
            }
        }
    }
}
