import AppKit
import Design
import SwiftUI

/// Settings > General: theme, login, quitting, the system service and About (the rest is on `ConnectionSettingsPage`).
struct GeneralSettingsPage: View {
    @EnvironmentObject private var model: AppModel
    @State private var confirmUninstall = false
    @AppStorage("quitAction") private var quitAction = "" // read by AppDelegate.quit
    @AppStorage(Prefs.autoCheckUpdates) private var autoCheck = true
    @AppStorage(Prefs.autoDownloadUpdates) private var autoDownload = true

    @AppStorage(Theme.key) private var theme = Theme.system.rawValue
    private static let quitLabels = ["": "Ask", "turnOff": "Disconnect", "keep": "Keep it on"]

    var body: some View {
        PageScaffold("Settings") {
            EmptyView()
        } content: {
            if model.status == nil { ServiceUnavailable() }
            warnings
            general
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
        else if ready { detail = "Downloaded and checked against this app's signature." }
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
            SectionTitle("Warnings")
            Panel {
                VStack(alignment: .leading, spacing: Space.s) {
                    ForEach(list, id: \.self) { NoteLine(.warning, $0) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Space.l)
            }
        }
    }

    // MARK: General

    @ViewBuilder private var general: some View {
        SectionTitle("General")
        Panel {
            FormRow("Theme", detail: "Light, dark, or follow the system.") {
                SelectMenu(title: (Theme(rawValue: theme) ?? .system).title, options: Theme.allCases, label: { $0.title },
                           selected: Theme(rawValue: theme) ?? .system) { t in
                    theme = t.rawValue
                    t.apply()
                }
            }
            Hairline()
            FormRow("Open at login", detail: "Show the connection state in the menu bar after you log in.") {
                toggle("Open at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
            }
            Hairline()
            FormRow("Global shortcut", detail: "Connects or disconnects from any app. None until you record one.") { ShortcutRecorder() }
            Hairline()
            FormRow("When quitting while connected",
                    detail: "The service runs on its own: with Keep it on, quitting only closes the menu bar icon.") {
                SelectMenu(title: Self.quitLabels[quitAction] ?? "Ask", options: ["", "turnOff", "keep"],
                           label: { Self.quitLabels[$0] ?? $0 }, selected: quitAction) { quitAction = $0 }
            }
        }
    }

    // MARK: System service

    @ViewBuilder private var service: some View {
        SectionTitle("System service")
        Panel {
            if model.serviceOutdated, let v = model.status?.version {
                FormRow("Update service", detail: "The service is version \(v); this app is \(AppModel.appVersion).") {
                    Button("Update") { Task { await model.restartService() } }
                        .buttonStyle(OutlineButtonStyle()).disabled(model.busy)
                }
                Hairline()
            }
            FormRow("Restart service",
                    detail: "Restarts the service from this app's copy of splitroute. The connection comes back by itself. Turn the service off or on in System Settings > General > Login Items.",
                    error: model.actionError) {
                Button("Restart") { Task { await model.restartService() } }
                    .buttonStyle(OutlineButtonStyle()).disabled(model.busy)
            }
            Hairline()
            FormRow("Uninstall service", detail: "Stops the service and disconnects. Your settings are kept.") {
                Button("Uninstall…", role: .destructive) { confirmUninstall = true }
                    .buttonStyle(OutlineButtonStyle()).disabled(model.busy || model.connError == .notRunning)
            }
        }
    }

    // MARK: About

    @ViewBuilder private var about: some View {
        SectionTitle("About")
        Panel {
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
            FormRow("Check for updates automatically", detail: "Once a day, Splitroute asks GitHub for the latest version while it runs.") {
                settingsSwitch("Check for updates automatically", isOn: Binding(get: { autoCheck }, set: { on in
                    autoCheck = on
                    if on { Task { await model.checkForUpdate(manual: false) } } else { model.forgetRelease() }
                }))
            }
            Hairline()
            FormRow("Download updates automatically", detail: "When the daily check finds a newer version, download it so it is ready to install. It is checked against this app's signature, and nothing is installed until you choose to.") {
                settingsSwitch("Download updates automatically", isOn: $autoDownload).disabled(!autoCheck)
            }
        }
    }
}
