import AppKit
import Design
import SwiftUI

/// Settings by category: General, Connection, Kill switch, System service and About.
struct SettingsPage: View {
    @EnvironmentObject private var model: AppModel
    @State private var confirmUninstall = false
    @AppStorage("quitAction") private var quitAction = "" // read by AppDelegate.quit

    private static let repo = URL(string: "https://github.com/split-route/macos")!
    private static let releases = URL(string: "https://github.com/split-route/macos/releases")!
    private static let rules = URL(string: "https://github.com/split-route/routing-rules")!
    @AppStorage(Theme.key) private var theme = Theme.system.rawValue
    private static let quitLabels = ["": "Ask", "turnOff": "Disconnect", "keep": "Keep it on"]
    private static let bootstrapLabels = ["": "Automatic", "1.1.1.1": "Cloudflare (1.1.1.1)", "8.8.8.8": "Google (8.8.8.8)", "9.9.9.9": "Quad9 (9.9.9.9)", "system": "System resolver"]

    var body: some View {
        PageScaffold("Settings") {
            EmptyView()
        } content: {
            if model.status == nil { ServiceUnavailable() }
            warnings
            general
            if model.status != nil { connection; killSwitch }
            service
            about
        }
        .confirmationDialog("Uninstall the Splitroute service?", isPresented: $confirmUninstall) {
            Button("Uninstall", role: .destructive) { Task { await model.uninstallService() } }
        } message: {
            Text("Servers disconnect and routing stops until you install the service again.")
        }
    }

    private func toggle(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(title, isOn: isOn).labelsHidden().toggleStyle(.switch).tint(Accent.color)
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

    // MARK: Connection

    @ViewBuilder private var connection: some View {
        SectionTitle("Connection")
        Panel {
            FormRow("Find servers with",
                    detail: "Automatic asks Cloudflare, Google and Quad9 when you connect and uses the first that answers from your network, because networks block different ones. Pick one yourself if a server still fails with \"connection reset by peer\" or times out. The system resolver can return a blocked network's fake address.",
                    error: model.error("bootstrap")) {
                SelectMenu(title: Self.bootstrapLabels[model.bootstrap] ?? model.bootstrap, options: ["", "1.1.1.1", "8.8.8.8", "9.9.9.9", "system"],
                           label: { Self.bootstrapLabels[$0] ?? $0 }, selected: model.bootstrap) { v in Task { await model.setBootstrap(v) } }
                    .disabled(model.busy)
            }
            Hairline()
            FormRow("Block QUIC (HTTP/3)",
                    detail: "A browser can hide a site's name inside QUIC, so a Block list misses it. With this on, QUIC that no list matched is refused and the browser uses regular HTTPS, where the name is visible.",
                    error: model.error("blockQUIC")) {
                toggle("Block QUIC", isOn: Binding(get: { model.config?.blockQUIC ?? true },
                                                   set: { on in Task { await model.setBlockQUIC(on) } }))
            }
        }
    }

    // MARK: Kill switch

    @ViewBuilder private var killSwitch: some View {
        SectionTitle("Kill switch")
        Panel {
            FormRow("Block traffic if the connection drops",
                    detail: "While connected, only your servers' own connections can leave this Mac. If the server fails, the network stops instead of using your normal connection.",
                    error: model.error("killswitch")) {
                toggle("Block traffic if the connection drops", isOn: Binding(get: { model.killSwitchOn }, set: { on in Task { await model.setKillSwitch(on: on) } }))
                    .disabled(model.busy)
            }
            Hairline()
            FormRow("Allow the local network", detail: "Printers, file shares and your router stay reachable while traffic is blocked.") {
                toggle("Allow the local network", isOn: Binding(get: { model.killSwitchLAN }, set: { on in Task { await model.setKillSwitch(lan: on) } }))
                    .disabled(model.busy || !model.killSwitchOn)
            }
            Hairline()
            NoteLine(.warning, "Programs running as root can still reach the network. The kill switch also stays on after a restart: the network is blocked until the connection is up, so keep the app set to open at login. Uninstalling the service turns it off.")
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Space.l)
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
            ValueRow("Version", AppModel.appVersion + (model.status.map { $0.version != AppModel.appVersion ? ", service \($0.version)" : "" } ?? ""))
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
