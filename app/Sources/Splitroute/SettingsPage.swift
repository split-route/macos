import AppKit
import Design
import SwiftUI

/// General, list source, files, the system service and About, as sections of one page.
struct SettingsPage: View {
    @EnvironmentObject private var model: AppModel
    @State private var presetID = ""
    @State private var confirmPreset = false
    @State private var baseURL = ""
    @State private var confirmUninstall = false
    @AppStorage("quitAction") private var quitAction = "" // read by AppDelegate.quit

    static let defaultBaseURL = "https://github.com/aliraghebi/routing-rules/releases/latest/download" // config.DefaultBaseURL
    static let logPath = "/var/log/splitroute.log"
    static let databasePath = "/var/db/splitroute/splitroute.db"
    private static let repo = URL(string: "https://github.com/split-route/macos")!
    private static let releases = URL(string: "https://github.com/split-route/macos/releases")!
    private static let rules = URL(string: "https://github.com/aliraghebi/routing-rules")!
    private static let quitLabels = ["": "Ask", "turnOff": "Turn the VPN off", "keep": "Keep it on"]

    private var saved: String { model.config?.baseURL ?? "" }

    var body: some View {
        PageScaffold("Settings", summary: "Version \(AppModel.appVersion)") {
            EmptyView()
        } content: {
            if model.status == nil { ServiceUnavailable() } else { routing }
            if model.status != nil { lookup; killSwitch }
            app
            if model.ready { source }
            files
            service
            about
        }
        .onAppear { baseURL = saved }
        .onChange(of: saved) { _, new in baseURL = new }
        .confirmationDialog("Uninstall the Splitroute service?", isPresented: $confirmUninstall) {
            Button("Uninstall", role: .destructive) { Task { await model.uninstallService() } }
        } message: {
            Text("Tunnels disconnect and routing stops until you install the service again.")
        }
    }

    private func toggle(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(title, isOn: isOn).labelsHidden().toggleStyle(.switch).tint(Accent.color)
    }

    // MARK: Lists and presets

    @ViewBuilder private var routing: some View {
        SectionTitle("Lists")
        Panel {
            FormRow("Apply lists",
                    detail: model.status?.enabled == false
                        ? "Off: connected tunnels carry all traffic."
                        : "On: each list goes direct, is blocked, or goes through its tunnel.",
                    error: model.actionError) {
                toggle("Apply lists", isOn: Binding(get: { model.status?.enabled ?? false },
                                                    set: { on in Task { await model.setEnabled(on) } }))
                    .disabled(model.busy)
            }
            if model.serviceOutdated, let v = model.status?.version {
                Hairline()
                FormRow("Service update", detail: "The service is version \(v); this app is \(AppModel.appVersion).") {
                    Button("Update service") { Task { await model.restartService() } }
                        .buttonStyle(OutlineButtonStyle()).disabled(model.busy)
                }
            }
            if model.ready {
                Hairline()
                FormRow("Preset", detail: presetDescription, error: model.error("preset")) {
                    HStack(spacing: Space.s) {
                        SelectMenu(title: model.presets.first { $0.id == presetID }?.name ?? "Choose…",
                                   options: model.presets.map(\.id),
                                   label: { id in model.presets.first { $0.id == id }?.name ?? id },
                                   selected: presetID) { presetID = $0 }
                        Button("Apply…") { confirmPreset = true }
                            .buttonStyle(OutlineButtonStyle()).disabled(presetID.isEmpty || model.busy)
                    }
                }
            }
            ForEach(model.status?.warnings ?? [], id: \.self) { w in
                Hairline()
                NoteLine(.warning, w).frame(maxWidth: .infinity, alignment: .leading).padding(Space.l)
            }
        }
        .confirmationDialog("Apply this preset?", isPresented: $confirmPreset) {
            Button("Apply") { Task { await model.applyPreset(presetID) } }
        } message: {
            Text("The current release lists are replaced. Your own lists and imports are kept.")
        }
    }

    private var presetDescription: String {
        guard let p = model.presets.first(where: { $0.id == presetID }) else {
            return "Replaces the release lists with a ready-made set. Your own lists and imports are kept."
        }
        return p.lists.map { "\($0.action.label): \($0.name)" }.joined(separator: ", ")
    }

    // MARK: App

    private static let bootstrapLabels = ["": "Google (8.8.8.8)", "1.1.1.1": "Cloudflare (1.1.1.1)", "9.9.9.9": "Quad9 (9.9.9.9)", "system": "System resolver"]

    @ViewBuilder private var lookup: some View {
        SectionTitle("Server lookup")
        Panel {
            FormRow("Find tunnel servers with",
                    detail: "If every tunnel fails with \"connection reset by peer\", your network blocks this DNS provider: pick another. The system resolver can return a blocked network's fake address.",
                    error: model.error("bootstrap")) {
                SelectMenu(title: Self.bootstrapLabels[model.bootstrap] ?? model.bootstrap, options: ["", "1.1.1.1", "9.9.9.9", "system"],
                           label: { Self.bootstrapLabels[$0] ?? $0 }, selected: model.bootstrap) { v in Task { await model.setBootstrap(v) } }
                    .disabled(model.busy)
            }
        }
    }

    @ViewBuilder private var killSwitch: some View {
        SectionTitle("Kill switch")
        Panel {
            FormRow("Block traffic if the VPN drops",
                    detail: "While the VPN is on, only the VPN's own connections can leave this Mac. If the tunnel fails, the network stops instead of using your normal connection.",
                    error: model.error("killswitch")) {
                toggle("Block traffic if the VPN drops", isOn: Binding(get: { model.killSwitchOn }, set: { on in Task { await model.setKillSwitch(on: on) } }))
                    .disabled(model.busy)
            }
            Hairline()
            FormRow("Allow the local network", detail: "Printers, file shares and your router stay reachable while traffic is blocked.") {
                toggle("Allow the local network", isOn: Binding(get: { model.killSwitchLAN }, set: { on in Task { await model.setKillSwitch(lan: on) } }))
                    .disabled(model.busy || !model.killSwitchOn)
            }
            Hairline()
            VStack(alignment: .leading, spacing: Space.s) {
                NoteLine(.warning, "The rules stay in force if the service or this app stops. To remove them, turn this off or the VPN off; if the app can't open, run: sudo splitroute killswitch off")
                NoteLine(.warning, "Programs running as root can still reach the network. It also stays on after a restart: the network is blocked until the VPN connects, so keep the app at login. Uninstalling the service turns it off.")
            }
        }
    }

    @ViewBuilder private var app: some View {
        SectionTitle("App")
        Panel {
            FormRow("Open at login", detail: "Show the connection state in the menu bar after you log in.") {
                toggle("Open at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
            }
            Hairline()
            FormRow("When quitting while the VPN is on",
                    detail: "The service runs on its own: with Keep it on, quitting only closes the menu bar icon.") {
                SelectMenu(title: Self.quitLabels[quitAction] ?? "Ask", options: ["", "turnOff", "keep"],
                           label: { Self.quitLabels[$0] ?? $0 }, selected: quitAction) { quitAction = $0 }
            }
        }
    }

    // MARK: List source

    @ViewBuilder private var source: some View {
        SectionTitle("List source")
        Panel {
            VStack(alignment: .leading, spacing: Space.m) {
                Text("Release URL").font(TypeScale.bodyStrong).foregroundStyle(Palette.ink.color)
                Text("Where release lists and their SHA256SUMS are downloaded from (https only). Empty: the routing-rules releases.")
                    .font(TypeScale.secondary).foregroundStyle(Palette.inkSecondary.color)
                    .fixedSize(horizontal: false, vertical: true)
                TextField("Release URL", text: $baseURL, prompt: Text(Self.defaultBaseURL))
                    .labelsHidden().textFieldStyle(.roundedBorder).fontDesign(.monospaced).onSubmit(saveURL)
                if let e = model.error("baseURL") { NoteLine(.error, e) }
                HStack(spacing: Space.s) {
                    Spacer()
                    Button("Use default") { baseURL = ""; saveURL() }
                        .buttonStyle(OutlineButtonStyle()).disabled(saved.isEmpty || model.busy)
                    Button("Save", action: saveURL)
                        .buttonStyle(OutlineButtonStyle())
                        .disabled(baseURL.trimmingCharacters(in: .whitespaces) == saved || model.busy)
                }
            }
            .padding(Space.l)
        }
    }

    // MARK: Files, service, about

    @ViewBuilder private var files: some View {
        SectionTitle("Files")
        Panel {
            FormRow("Log file", detail: Self.logPath) {
                Button("Show in Finder") { reveal(Self.logPath) }.buttonStyle(OutlineButtonStyle())
            }
            Hairline()
            FormRow("Settings database",
                    detail: "\(Self.databasePath)\nExport or import it as JSON with splitroute config export / import.") {
                Button("Show in Finder") { reveal(Self.databasePath) }.buttonStyle(OutlineButtonStyle())
            }
        }
    }

    @ViewBuilder private var service: some View {
        SectionTitle("System service")
        Panel {
            FormRow("Restart service",
                    detail: "Restarts the service from this app's copy of splitroute. The VPN comes back on by itself. Turn the service off or on in System Settings > General > Login Items.",
                    error: model.actionError) {
                Button("Restart") { Task { await model.restartService() } }
                    .buttonStyle(OutlineButtonStyle()).disabled(model.busy)
            }
            Hairline()
            FormRow("Uninstall service", detail: "Stops the service and turns the VPN off. Your settings are kept.") {
                Button("Uninstall…", role: .destructive) { confirmUninstall = true }
                    .buttonStyle(OutlineButtonStyle()).disabled(model.busy || model.connError == .notRunning)
            }
        }
    }

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
            FormRow("Lists", detail: "github.com/aliraghebi/routing-rules") {
                Link("Open", destination: Self.rules).font(TypeScale.bodyStrong)
            }
            Hairline()
            ValueRow("License", "GPL-3.0")
        }
    }

    private func saveURL() {
        let u = baseURL.trimmingCharacters(in: .whitespaces)
        guard u != saved else { return }
        Task { await model.setBaseURL(u.isEmpty ? nil : u) }
    }

    private func reveal(_ path: String) {
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }
}
