import AppKit
import Design
import SwiftUI

/// Settings > General: theme, login, quitting, the system service and About (the rest is on `ConnectionSettingsPage`).
struct SettingsPage: View {
    @EnvironmentObject private var model: AppModel
    @State private var confirmUninstall = false
    @AppStorage("quitAction") private var quitAction = "" // read by AppDelegate.quit
    @AppStorage(Prefs.autoCheckUpdates) private var autoCheck = true
    @AppStorage(Prefs.autoDownloadUpdates) private var autoDownload = true

    private static let repo = URL(string: "https://github.com/split-route/macos")!
    private static let releases = URL(string: "https://github.com/split-route/macos/releases")!
    private static let rules = URL(string: "https://github.com/split-route/routing-rules")!
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

    /// Check, Download (with its progress) or Install, whichever fits where the update is.
    @ViewBuilder private var updateAction: some View {
        let blocked = model.updateBlockedReason
        if let r = model.newerRelease, blocked == nil, r.zip != nil {
            if model.stagedUpdate == r.version {
                Button("Install…") { model.confirmingInstall = true }.buttonStyle(SolidButtonStyle())
            } else if case .running(let p)? = model.updateDownload {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(p.map { "\(Int($0 * 100))%" } ?? "Downloading…").font(TypeScale.secondary).monospacedDigit()
                }
            } else {
                Button("Download") { Task { await model.downloadUpdate() } }.buttonStyle(SolidButtonStyle())
            }
        }
        Button("Check for updates") { Task { await model.checkForUpdate(manual: true) } }
            .buttonStyle(OutlineButtonStyle()).disabled(model.checkingUpdate)
    }

    /// What to say under the Version row: why an update can't be installed here, a failure, or the result of a check.
    private var updateNote: (text: String, error: Bool)? {
        if case .failed(let why)? = model.updateDownload { return (why, true) }
        if model.newerRelease != nil, let why = model.updateBlockedReason { return (why, false) }
        if let n = model.updateCheckNote { return (n, n.hasPrefix("Couldn't")) }
        return nil
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
                    if let r = model.newerRelease {
                        HStack(spacing: 6) {
                            Circle().fill(Palette.success.color).frame(width: 8, height: 8)
                            Link(model.stagedUpdate == r.version ? "\(r.version) is ready" : "\(r.version) is available", destination: r.page)
                                .font(TypeScale.bodyStrong)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    if model.checkingUpdate { ProgressView().controlSize(.small) }
                    updateAction
                }
            }
            if let note = updateNote {
                Group {
                    if note.error { NoteLine(.error, note.text) } else {
                        Text(note.text).font(TypeScale.secondary).foregroundStyle(Palette.inkSecondary.color)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, Space.l).padding(.bottom, Space.m)
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
            Hairline()
            FormRow("Updates", detail: "With Homebrew: brew upgrade --cask splitroute. Otherwise download the DMG from the releases page.") {
                Link("Releases", destination: Self.releases).font(TypeScale.bodyStrong)
            }
            Hairline()
            FormRow("Source code", detail: "github.com/split-route/macos") {
                Link("Open", destination: Self.repo).font(TypeScale.bodyStrong)
            }
            Hairline()
            FormRow("Lists", detail: "github.com/split-route/routing-rules") {
                Link("Open", destination: Self.rules).font(TypeScale.bodyStrong)
            }
            Hairline()
            ValueRow("License", "GPL-3.0")
        }
    }
}
