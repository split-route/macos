import AppKit
import Design
import SwiftUI

/// The window: a sidebar with four pages. Every change is sent to the service
/// when it is made; there is no Apply.
struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("settingsPage") private var page: Destination = .home


    var body: some View {
        Group {
            if #available(macOS 26, *) { nativeBody } else { legacyBody }
        }
        .font(TypeScale.body)
        .foregroundStyle(Palette.ink.color)
        .frame(minWidth: 936, minHeight: 630)
        .onAppear { if model.settingsVisible { model.traffic.start() } }
        .onChange(of: model.settingsVisible) { _, open in if open { model.traffic.start() } else { model.traffic.stop() } }
    }

    /// The page for the selected destination; the pages cross-fade.
    private var pages: some View {
        ZStack {
            switch page {
            case .home: HomePage(traffic: model.traffic, go: { page = $0 }).transition(.opacity)
            case .tunnels: TunnelsPage().transition(.opacity)
            case .lists: ListsPage().transition(.opacity)
            case .general: GeneralSettingsPage().transition(.opacity)
            case .network: NetworkSettingsPage().transition(.opacity)
            case .advanced: AdvancedSettingsPage().transition(.opacity)
            case .updates: UpdatesSettingsPage().transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.18), value: page) // the page you leave fades out as the new one fades in
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Home and Servers already show the connection; the other pages get it in the sidebar.
    private var sidebarStatus: String? {
        model.connError == nil && page != .home && page != .tunnels ? model.sidebarStatus : nil
    }

    /// macOS 26+: a floating Liquid Glass sidebar of a fixed width (no divider to drag, nothing to collapse).
    @available(macOS 26, *)
    private var nativeBody: some View {
        HStack(spacing: 0) {
            GlassSidebar(selection: $page, status: sidebarStatus, statusOn: model.health == .active)
                .frame(width: 250)
                .padding(8)
            pages
        }
        .background(Backdrop(material: .hudWindow, darkness: 0.82))
        .ignoresSafeArea()
    }

    /// Before macOS 26: the app's own sidebar over a blurred backdrop.
    private var legacyBody: some View {
        HStack(spacing: 0) {
            // The traffic lights sit over the sidebar's top: the title bar is transparent.
            Sidebar(selection: $page, tunnels: [], title: "Splitroute", subtitle: "Smart VPN & Routing",
                    icon: NSApp.applicationIconImage.map { Image(nsImage: $0) }, topInset: 30,
                    status: sidebarStatus, statusOn: model.health == .active)
            // The content is the darker, blurrier layer, so focus stays on it; the sidebar is lighter and clearer.
            pages.background(Backdrop(material: .hudWindow, darkness: 0.82))
        }
        .ignoresSafeArea()
    }
}

/// Capsule search field; Liquid Glass on macOS 26+.
struct SearchField: View {
    @Binding var text: String
    var prompt = "Search…"

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

/// A soft fill and hairline so the field reads on any background, with Liquid Glass
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
        Panel {
            if model.serviceNeedsApproval {
                FormRow("Allow the Splitroute service",
                        detail: "Turn on Splitroute under Allow in the Background in System Settings > General > Login Items. It changes routes, so it runs as a system service.",
                        error: model.actionError) {
                    Button("Open Login Items") { model.openLoginItems() }.buttonStyle(SolidButtonStyle())
                }
            } else if model.serviceNotStarting {
                FormRow("The Splitroute service isn't starting",
                        detail: model.appQuarantined
                            ? "macOS blocks it because the app is still marked as downloaded from the internet. In Terminal, run: xattr -dr com.apple.quarantine \(Bundle.main.bundlePath)"
                            : "It's allowed but launchd can't start it. Check it under Allow in the Background, and the log at /var/log/splitroute.log.",
                        error: model.actionError) {
                    Button("Open Login Items") { model.openLoginItems() }.buttonStyle(SolidButtonStyle())
                }
            } else {
                FormRow(model.connError?.localizedDescription ?? "Connecting to the service…",
                        detail: "Splitroute runs as a system service so it can change routes. You allow it once in System Settings > Login Items.",
                        error: model.actionError) {
                    if model.connError == .notRunning {
                        Button("Install service") { Task { await model.installService() } }
                            .buttonStyle(SolidButtonStyle()).disabled(model.busy)
                    }
                }
            }
        }
    }
}

extension AppModel {
    /// Server names as the Servers page orders them: the ones added by hand first, then each subscription's in the order
    /// the subscriptions were added. Menus use it so a long subscription never pushes your own servers out of sight.
    var tunnelNamesLocalFirst: [String] {
        let subs = (tunnelList?.subscriptions ?? []).map(\.name)
        // Favorites first, then the servers added by hand, then each subscription's.
        let rank = { (t: Tunnel) -> Int in
            t.pinned ? -1 : (t.group.flatMap { subs.firstIndex(of: $0) }.map { $0 + 1 } ?? (t.group == nil ? 0 : subs.count + 1))
        }
        return tunnels.enumerated().sorted { a, b in
            let (x, y) = (rank(a.element), rank(b.element))
            return x != y ? x < y : a.offset < b.offset
        }.map(\.element.name)
    }

    /// The service answers and its config is loaded.
    var ready: Bool { connError == nil && config != nil }
}

/// The sidebar on macOS 26+: one glass panel inset from the window edge (the traffic lights sit on it), the app's name,
/// the pages, and the connection status at the foot.
@available(macOS 26, *)
private struct GlassSidebar: View {
    @Binding var selection: Destination
    let status: String?
    let statusOn: Bool
    @Namespace private var ns
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    @State private var commandHeld = false
    @State private var flagsMonitor: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: Space.m) {
                if let icon = NSApp.applicationIconImage {
                    Image(nsImage: icon).resizable().frame(width: 40, height: 40).accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("Splitroute").font(TypeScale.heading).foregroundStyle(Palette.ink.color).lineLimit(1)
                    Text("Smart VPN & Routing").font(TypeScale.secondary).foregroundStyle(Palette.inkSecondary.color).lineLimit(1)
                }
            }
            .padding(.horizontal, Space.s).padding(.top, 38).padding(.bottom, Space.l)
            ForEach(Array(Destination.allCases.enumerated()), id: \.element) { index, d in
                let on = selection == d
                if d == Destination.settingsPages.first { SidebarSectionTitle("Settings") }
                Button {
                    if reduceMotion { selection = d } else { withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) { selection = d } }
                } label: {
                    HStack(spacing: Space.m) {
                        DestinationIcon(d, selected: on, plain: on ? Color.white : Palette.inkSecondary.color)
                        Text(d.title).font(TypeScale.sidebar).foregroundStyle(on ? Color.white : Palette.inkSecondary.color)
                        Spacer(minLength: 0)
                        // The shortcut shows only while Command is held, like a menu's.
                        Text("⌘\(index + 1)").font(TypeScale.secondary).foregroundStyle(on ? Color.white.opacity(0.8) : Palette.inkSecondary.color.opacity(0.7))
                            .opacity(commandHeld ? 1 : 0)
                            .animation(.easeOut(duration: 0.12), value: commandHeld)
                    }
                    .padding(.vertical, 7).padding(.horizontal, Space.m)
                    .background {
                        if on {
                            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Accent.color)
                                .matchedGeometryEffect(id: "selection", in: ns)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
            Spacer(minLength: 0)
            if let status {
                HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                    Circle().fill(statusOn ? Palette.success.color : .clear)
                        .overlay(Circle().stroke(Palette.inkSecondary.color, lineWidth: statusOn ? 0 : 1.5))
                        .frame(width: 9, height: 9)
                    Text(status).font(TypeScale.secondary).foregroundStyle(Palette.inkSecondary.color)
                        .lineLimit(1).truncationMode(.tail)
                }
                .help(status)
                .padding(.horizontal, Space.m).padding(.bottom, Space.s)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(Space.s)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { e in
                commandHeld = e.modifierFlags.contains(.command)
                return e
            }
        }
        .onDisappear { if let m = flagsMonitor { NSEvent.removeMonitor(m); flagsMonitor = nil }; commandHeld = false }
        // Releasing Command while another app is in front sends no event here, so leaving the app clears it too.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in commandHeld = false }
        .glassEffect(.regular.tint(scheme == .dark ? Color.black.opacity(0.18) : nil), in: RoundedRectangle(cornerRadius: 22, style: .continuous)) // dark: close to the page behind it
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous)) // cuts the glass's own drop shadow
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Glass.stroke, lineWidth: 0.5))
        .shadow(color: .black.opacity(scheme == .dark ? 0.30 : 0.10), radius: 7, y: 2) // a soft shadow of our own, lighter than the glass's
    }
}
