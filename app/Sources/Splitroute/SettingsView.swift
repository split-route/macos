import SwiftUI

enum Page: String, CaseIterable, Identifiable {
    case status, general, lists, tunnels, vpnSettings, advanced, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .lists: return "Lists"
        case .tunnels: return "VPN"
        case .vpnSettings: return "VPN Settings"
        case .status: return "Status"
        case .advanced: return "Advanced"
        case .about: return "About"
        }
    }

    var subtitle: String {
        switch self {
        case .general: return "Turn routing on or off, pick a preset, and choose how the app starts and quits."
        case .lists: return "Ready-made lists, lists imported from a URL or a file, and your own lists."
        case .tunnels: return "OpenVPN profiles: connect, disconnect and see their state."
        case .vpnSettings: return "Options that apply to every VPN protocol."
        case .status: return "What the service sees and the routes it has applied."
        case .advanced: return "List source, logs and the system service."
        case .about: return "Version and links."
        }
    }

    /// Row titles on the page, so the sidebar search finds the page by a setting's name.
    var keywords: [String] {
        switch self {
        case .general: return ["Routing", "Service update", "Preset", "Open at login", "Turn on routing when the app opens", "When quitting while routing"]
        case .tunnels: return ["OpenVPN", "Profile", ".ovpn", "Connect", "Credentials", "Keychain"]
        case .vpnSettings: return ["Kill switch", "VPN"]
        case .lists: return ["Add a list", "Ready-made", "Release lists", "Import", "URL", "File", "Custom", "Entries"]
        case .status: return ["Routing", "Gateway", "VPN", "Routes", "Release lists downloaded", "Service version"]
        case .advanced: return ["Release URL", "Log file", "Settings database", "Reinstall service", "Uninstall service"]
        case .about: return ["Updates", "Source code", "License", "Version"]
        }
    }

    /// Sidebar section; pages with no section are listed first, unlabeled.
    var section: String? {
        switch self {
        case .vpnSettings, .advanced: return "Settings"
        default: return nil
        }
    }

    func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty || ([title, subtitle] + keywords).contains { $0.localizedCaseInsensitiveContains(q) }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape.fill"
        case .lists: return "list.bullet.rectangle.fill"
        case .tunnels: return "lock.shield.fill"
        case .vpnSettings: return "lock.badge.clock.fill"
        case .status: return "waveform.path.ecg"
        case .advanced: return "wrench.and.screwdriver.fill"
        case .about: return "info.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .general: return .gray
        case .lists: return .blue
        case .tunnels: return .orange
        case .vpnSettings: return .orange
        case .status: return .green
        case .advanced: return .indigo
        case .about: return .teal
        }
    }
}

/// The settings window: a sidebar of pages. Every change is sent to the
/// service when it is made; there is no Apply.
struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("settingsPage") private var page: Page = .status
    @State private var query = ""
    @State private var back: [Page] = []
    @State private var forward: [Page] = []

    /// Selecting a page records it in the back/forward history, like System Settings.
    private func go(_ p: Page) {
        guard p != page else { return }
        back.append(page)
        forward.removeAll()
        page = p
    }

    private var visible: [Page] { Page.allCases.filter { $0 != .about && $0.matches(query) } }

    var body: some View {
        // Always both columns: the sidebar can't be collapsed (by dragging or a shortcut).
        NavigationSplitView(columnVisibility: .constant(.all)) {
            VStack(spacing: 0) {
                SearchField(text: $query).padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 12)
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(visible) { p in
                            if let s = p.section, visible.first(where: { $0.section == s }) == p {
                                Text(s).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 8).padding(.top, 12).padding(.bottom, 2)
                            }
                            SidebarRow(selected: page == p, action: { go(p) }) {
                                IconTile(symbol: p.symbol, color: p.color)
                                Text(p.title)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                }
                // App icon and version pinned to the bottom, like an account row; opens About.
                SidebarRow(selected: page == .about, action: { go(.about) }) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 32, height: 32)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Splitroute").font(.body.weight(.semibold)).fontDesign(.rounded)
                        Text("Version \(AppModel.appVersion)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(12)
            }
            // Fixed width like Raycast's sidebar; the divider doesn't drag.
            .frame(width: 232)
            .navigationSplitViewColumnWidth(min: 232, ideal: 232, max: 232)
            .modifier(NoSidebarToggle())
        } detail: {
            Group {
                switch page {
                case .general: GeneralPage()
                case .lists: ListsPage()
                case .tunnels: TunnelsPage()
                case .vpnSettings: VPNSettingsPage()
                case .status: StatusPage()
                case .advanced: AdvancedPage()
                case .about: AboutPage()
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background(Color.pageBackground.ignoresSafeArea())
            .navigationTitle(page.title)
            .toolbar {
                ToolbarItemGroup(placement: .navigation) {
                    Button { forward.append(page); page = back.removeLast() } label: { Image(systemName: "chevron.left") }
                        .disabled(back.isEmpty)
                        .help("Back")
                        .keyboardShortcut("[", modifiers: .command)
                    Button { back.append(page); page = forward.removeLast() } label: { Image(systemName: "chevron.right") }
                        .disabled(forward.isEmpty)
                        .help("Forward")
                        .keyboardShortcut("]", modifiers: .command)
                }
            }
        }
        // Fixed width like System Settings; only the height changes.
        .frame(width: 800)
        .frame(minHeight: 500)
    }
}

/// The sidebar toggle in the toolbar; the sidebar always shows (macOS 14+ can remove it).
private struct NoSidebarToggle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 14, *) { content.toolbar(removing: .sidebarToggle) } else { content }
    }
}

/// A sidebar entry: a soft gray highlight when selected, not the accent color,
/// so the sidebar stays quiet next to the content.
struct SidebarRow<Content: View>: View {
    let selected: Bool
    let action: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 8) {
            content
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.primary.opacity(selected ? 0.1 : 0)))
        .contentShape(Rectangle())
        // Select on mouse down with no pressed look, like System Settings' sidebar.
        .gesture(DragGesture(minimumDistance: 0).onChanged { _ in if !selected { action() } })
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { action() }
    }
}

/// Capsule search field; Liquid Glass on macOS 26+.
struct SearchField: View {
    @Binding var text: String
    var prompt = "Search settings…"

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(prompt, text: $text).textFieldStyle(.plain)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .modifier(CapsuleGlass())
    }
}

/// A soft fill and hairline so the field reads on any sidebar, with Liquid Glass
/// on top on macOS 26+.
struct CapsuleGlass: ViewModifier {
    func body(content: Content) -> some View {
        let base = content
            .background(Capsule().fill(Color.primary.opacity(0.06)))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
        if #available(macOS 26, *) {
            base.glassEffect(.regular, in: Capsule())
        } else {
            base
        }
    }
}

/// Shown on pages that need the service when it can't be reached.
struct ServiceUnavailable: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Section {
            if model.serviceNeedsApproval {
                SettingRow("Allow the Splitroute service",
                           description: "Turn on Splitroute under Allow in the Background in System Settings > General > Login Items. It changes routes, so it runs as a system service.",
                           error: model.actionError) {
                    Button("Open Login Items") { model.openLoginItems() }
                        .prominent()
                }
            } else if model.serviceNotStarting {
                SettingRow("The Splitroute service isn't starting",
                           description: model.appQuarantined
                               ? "macOS blocks it because the app is still marked as downloaded from the internet. In Terminal, run: xattr -dr com.apple.quarantine \(Bundle.main.bundlePath)"
                               : "It's allowed but launchd can't start it. Check it under Allow in the Background, and the log at /var/log/splitroute.log.",
                           error: model.actionError) {
                    Button("Open Login Items") { model.openLoginItems() }
                        .prominent()
                }
            } else {
                SettingRow(model.connError?.localizedDescription ?? "Connecting to the service…",
                           description: "Splitroute runs as a system service so it can change routes. You allow it once in System Settings > Login Items.",
                           error: model.actionError) {
                    if model.connError == .notRunning {
                        Button("Install Service") { Task { await model.installService() } }
                            .prominent()
                            .disabled(model.busy)
                    }
                }
            }
        }
    }
}

extension AppModel {
    /// The service answers and its config is loaded.
    var ready: Bool { connError == nil && config != nil }
}
