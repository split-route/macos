import SwiftUI

public enum Destination: String, CaseIterable, Sendable {
    // The raw values are stored in the user's defaults: keep them when a title changes.
    // The raw values are stored in the user's defaults (key "settingsPage"): keep them when a title changes, and when one has to
    // change, map the old value in `migrateStoredPage`.
    case home = "Home", tunnels = "Tunnels", lists = "Lists", general = "General", application = "Application", advanced = "Advanced"

    /// The sidebar's top group and its Settings group; the pages of the second are listed under a "Settings" title.
    /// The raw values these pages had before they were renamed: a saved page with an old value is moved to its new one.
    private static let renamed = ["Settings": "General", "Connection": "General", "Network": "General", "Updates": "General"]

    /// Moves a saved page from a name it had to the one it has now (otherwise the app would open on Home once).
    public static func migrateStoredPage(_ defaults: UserDefaults = .standard, key: String = "settingsPage") {
        if let v = defaults.string(forKey: key), let n = renamed[v] { defaults.set(n, forKey: key) }
    }

    public static let mainPages: [Destination] = [.home, .tunnels, .lists]
    public static let settingsPages: [Destination] = [.general, .application, .advanced]

    public var title: String {
        switch self {
        case .home: return "Home"
        case .tunnels: return "Servers"
        case .lists: return "Routing"
        case .general: return "General"
        case .application: return "Application"
        case .advanced: return "Advanced"
        }
    }

    /// A few muted words under a settings page's name in the sidebar.
    public var subtitle: String? {
        switch self {
        case .general: return "Connection, updates"
        case .application: return "Theme, startup, version"
        case .advanced: return "Network, engine, tests"
        default: return nil
        }
    }

    public var symbol: String {
        switch self {
        case .home: return "house"
        case .tunnels: return "shield"
        case .lists: return "arrow.triangle.branch"
        case .general: return "gearshape"
        case .application: return "macwindow"
        case .advanced: return "slider.horizontal.3"
        }
    }
}

// MARK: Sidebar

public extension Destination {
    /// The tile behind the page's icon in the sidebar.
    var tileTone: Tone {
        switch self {
        case .home: return Tone(light: 0x2F7BF0, dark: 0x3B86F5)
        case .tunnels: return Tone(light: 0x2FB85A, dark: 0x34C05F)
        case .lists: return Tone(light: 0x9B4FD8, dark: 0xA55CE0)
        case .general: return Tone(light: 0x7C7C84, dark: 0x8A8A92)
        case .application: return Tone(light: 0x1F9FD8, dark: 0x2BA8E0)
        case .advanced: return Tone(light: 0x5B5FC7, dark: 0x6A6EDB)
        }
    }
}

/// A page's sidebar icon: a colored rounded tile with a white glyph, or (UserDefaults "sidebarTiles" off) the plain glyph
/// in `plain`. Kept switchable to compare the two looks.
public struct DestinationIcon: View {
    let destination: Destination
    let selected: Bool
    let plain: Color
    @AppStorage("sidebarTiles") private var tiles = true
    public init(_ destination: Destination, selected: Bool = false, plain: Color) { self.destination = destination; self.selected = selected; self.plain = plain }
    public var body: some View {
        if tiles {
            let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
            // On the selected row (solid blue) the tile turns white and the glyph takes the accent, like Telegram's.
            Image(systemName: destination.symbol).font(.system(size: 14, weight: .semibold))
                .foregroundStyle(selected ? Accent.color : Color.white)
                .frame(width: 28, height: 28)
                .background(shape.fill(selected ? AnyShapeStyle(Color.white)
                                                : AnyShapeStyle(LinearGradient(colors: [destination.tileTone.color.opacity(0.85), destination.tileTone.color], startPoint: .top, endPoint: .bottom))))
                .overlay(shape.strokeBorder(Color.white.opacity(selected ? 0 : 0.18), lineWidth: 0.5))
                .accessibilityHidden(true)
        } else {
            Image(systemName: destination.symbol).font(.system(size: 17, weight: .regular)).frame(width: 28).foregroundStyle(plain)
        }
    }
}

/// The small title over a group of sidebar items.
public struct SidebarSectionTitle: View {
    let title: String
    public init(_ title: String) { self.title = title }
    public var body: some View {
        Text(title).font(TypeScale.secondary).foregroundStyle(Palette.inkSecondary.color)
            .padding(.horizontal, Space.m).padding(.top, Space.xl).padding(.bottom, 4)
            .accessibilityAddTraits(.isHeader)
    }
}

public struct Sidebar: View {
    @Namespace private var selectionNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var selection: Destination
    let tunnels: [TunnelItem]
    /// Space above the title for the window's traffic lights.
    let topInset: CGFloat
    let title: String
    let subtitle: String?
    let icon: Image?
    /// Tunnels that exist but aren't listed (the list shows only those that are on).
    let moreCount: Int
    /// One line about the VPN at the foot of the sidebar (a dot, filled when it is on), or nil.
    let status: String?
    let statusOn: Bool
    public init(selection: Binding<Destination>, tunnels: [TunnelItem], title: String = "Split Route", subtitle: String? = nil,
                icon: Image? = nil, topInset: CGFloat = 0, moreCount: Int = 0, status: String? = nil, statusOn: Bool = false) {
        self._selection = selection; self.tunnels = tunnels; self.title = title; self.subtitle = subtitle; self.icon = icon
        self.topInset = topInset; self.moreCount = moreCount
        self.status = status; self.statusOn = statusOn
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: Space.m) {
                if let icon {
                    icon.resizable().frame(width: 44, height: 44).accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(TypeScale.heading).foregroundStyle(Palette.ink.color)
                    if let subtitle { Text(subtitle).font(TypeScale.secondary).foregroundStyle(Palette.inkSecondary.color).lineLimit(1) }
                }
            }
            .padding(.horizontal, Space.s).padding(.top, topInset).padding(.bottom, Space.xl)
            ForEach(Array(Destination.allCases.enumerated()), id: \.element) { index, d in
                let on = selection == d
                if d == Destination.settingsPages.first { SidebarSectionTitle("Settings") }
                Button {
                    if reduceMotion { selection = d } else { withAnimation(.spring(response: 0.2, dampingFraction: 0.9)) { selection = d } }
                } label: {
                    HStack(spacing: Space.m) {
                        DestinationIcon(d, selected: on, plain: on ? Color.white : Palette.inkSecondary.color)
                            .shadow(color: on ? Accent.lightTone.color.opacity(0.7) : .clear, radius: 4)
                        // The weight changes with the selection: animating that makes the letters swell and shrink, so the text snaps.
                        VStack(alignment: .leading, spacing: 1) {
                            Text(d.title).font(on ? TypeScale.sidebarStrong : TypeScale.sidebar)
                                .transaction { $0.animation = nil }
                            if let s = d.subtitle {
                                Text(s).font(.system(size: 11)).foregroundStyle(on ? Color.white.opacity(0.75) : Palette.inkSecondary.color.opacity(0.7))
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                    }
                    .foregroundStyle(on ? Color.white : Palette.inkSecondary.color)
                    .padding(.vertical, 8).padding(.horizontal, Space.m)
                    .background {
                        if on {
                            // One highlight that moves, not one that disappears and another that appears.
                            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Accent.color)
                                .matchedGeometryEffect(id: "selection", in: selectionNamespace)
                        }
                    }
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: on) // the icon color
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
            Spacer()
            if let status {
                HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                    Circle().fill(statusOn ? Palette.success.color : .clear)
                        .overlay(Circle().stroke(Palette.inkSecondary.color, lineWidth: statusOn ? 0 : 1.5))
                        .frame(width: 9, height: 9)
                    Text(status).font(TypeScale.secondary).foregroundStyle(Palette.inkSecondary.color)
                        .lineLimit(1).truncationMode(.tail)
                }
                .help(status)
                .padding(.horizontal, Space.m)
                .accessibilityElement(children: .combine)
            }
            if (!tunnels.isEmpty || moreCount > 0), selection != .tunnels {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(tunnels) { t in
                        HStack(spacing: 8) {
                            LineMark(state: t.state, line: t.line).frame(width: 36, height: 12)
                            Text(t.name).font(TypeScale.secondary).foregroundStyle(Palette.inkSecondary.color).lineLimit(1)
                        }
                    }
                    if moreCount > 0 {
                        Text("and \(moreCount) more").font(TypeScale.secondary).foregroundStyle(Palette.inkSecondary.color)
                    }
                }
                .padding(.horizontal, Space.m)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Self.summary(tunnels))
            }
        }
        .padding(Space.m).padding(.top, Space.s)
        .frame(width: 232)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(Backdrop(material: .sidebar, darkness: 0.38).overlay(Glass.sidebar))
        .overlay(alignment: .trailing) { Rectangle().fill(Glass.stroke).frame(width: 1) }
    }

    static func summary(_ t: [TunnelItem]) -> String {
        let on = t.filter { $0.state == .connected }.count
        return on == 0 ? "No server connected" : "\(on) of \(t.count) servers connected"
    }
}

// MARK: Tunnels

public struct TunnelRow: View {
    let tunnel: TunnelItem
    public init(_ tunnel: TunnelItem) { self.tunnel = tunnel }
    public var body: some View {
        HStack(spacing: Space.l) {
            LineMark(state: tunnel.state, line: tunnel.line).frame(width: 72, height: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(tunnel.name).font(TypeScale.bodyStrong).foregroundStyle(Palette.ink.color).lineLimit(1)
                if case .failed(let why) = tunnel.state {
                    Text(why).font(TypeScale.secondary).foregroundStyle(Palette.danger.color)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(tunnel.detail).font(TypeScale.secondary).foregroundStyle(Palette.inkSecondary.color).lineLimit(1)
                }
            }
            Spacer(minLength: Space.m)
            Text(tunnel.state.label).font(TypeScale.secondary).foregroundStyle(Palette.inkSecondary.color)
            Button(tunnel.state.actionTitle) {}.buttonStyle(OutlineButtonStyle())
        }
        .padding(.vertical, Space.m).padding(.horizontal, Space.l)
        .accessibilityElement(children: .combine)
    }
}

public struct TunnelsScreen: View {
    let tunnels: [TunnelItem]
    public init(tunnels: [TunnelItem]) { self.tunnels = tunnels }

    public var body: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            PageHeader("Servers") {
                if !tunnels.isEmpty { Button("Add server") {}.buttonStyle(SolidButtonStyle()) }
            }
            if tunnels.isEmpty {
                Panel { EmptyState(title: "Add your first server",
                                   message: "Import an OpenVPN profile to connect, then choose which lists go through it.",
                                   action: "Import a profile") }
            } else {
                Panel {
                    ForEach(Array(tunnels.enumerated()), id: \.element.id) { i, t in
                        if i > 0 { Hairline() }
                        TunnelRow(t)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: Lists

public struct ListRow: View {
    let item: ListItem
    @Binding var action: ListAction
    let tunnels: [TunnelItem]
    var forceFocus = false

    public init(_ item: ListItem, action: Binding<ListAction>, tunnels: [TunnelItem], forceFocus: Bool = false) {
        self.item = item; self._action = action; self.tunnels = tunnels; self.forceFocus = forceFocus
    }

    var tunnel: TunnelItem? { tunnels.first { $0.id == item.tunnelID } ?? tunnels.first }

    public var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(spacing: Space.l) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name).font(TypeScale.bodyStrong).foregroundStyle(Palette.ink.color).lineLimit(1)
                        .help(item.name)
                    Text(item.note).font(TypeScale.secondary).foregroundStyle(Palette.inkSecondary.color).lineLimit(1)
                        .monospacedDigit()
                }
                .layoutPriority(-1)
                Spacer(minLength: Space.m)
                if action == .tunnel, !tunnels.isEmpty {
                    Menu {
                        ForEach(tunnels) { t in Button(t.name) {} }
                    } label: {
                        HStack(spacing: 4) {
                            TunnelChip(name: tunnel?.name ?? "No server", line: tunnel?.line ?? .cobalt)
                            Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(Palette.inkSecondary.color)
                        }
                    }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
                    .accessibilityLabel("Server for \(item.name)")
                }
                ActionChoice(listName: item.name, selection: $action, tunnelLine: tunnel?.line, forceFocus: forceFocus)
            }
            if action == .tunnel, let t = tunnel, t.state != .connected {
                Text("\(t.name) isn't connected, so this list is blocked until it is.")
                    .font(TypeScale.secondary).foregroundStyle(Palette.danger.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let problem = item.problem {
                HStack(spacing: Space.m) {
                    Text(problem).font(TypeScale.secondary).foregroundStyle(Palette.danger.color)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Retry") {}.buttonStyle(OutlineButtonStyle())
                }
            }
        }
        .padding(.vertical, Space.m).padding(.horizontal, Space.l)
    }
}

public struct ListsScreen: View {
    @Binding var lists: [ListItem]
    let tunnels: [TunnelItem]
    let focusFirst: Bool
    @State private var rest: ListAction = .tunnel

    public init(lists: Binding<[ListItem]>, tunnels: [TunnelItem], focusFirst: Bool = false) {
        self._lists = lists; self.tunnels = tunnels; self.focusFirst = focusFirst
    }

    var defaultTunnel: TunnelItem? { tunnels.first { $0.state == .connected } }

    public var body: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            PageHeader("Routing") {
                if !lists.isEmpty { Button("Add list") {}.buttonStyle(SolidButtonStyle()) }
            }
            if lists.isEmpty {
                Panel { EmptyState(title: "Choose where traffic goes",
                                   message: "A list is a set of sites or address ranges. Send each one direct, block it, or route it through a server.",
                                   action: "Add a list") }
            } else {
                ScrollView {
                    Panel {
                        ForEach(Array(lists.enumerated()), id: \.element.id) { i, l in
                            if i > 0 { Hairline() }
                            ListRow(l, action: Binding(get: { lists[i].action }, set: { lists[i].action = $0 }),
                                    tunnels: tunnels, forceFocus: focusFirst && i == 0)
                        }
                        Hairline()
                        HStack {
                            Text("Default Route").font(TypeScale.bodyStrong).foregroundStyle(Palette.ink.color)
                            Spacer()
                            ActionChoice(listName: "default route", selection: $rest,
                                         tunnelLine: defaultTunnel?.line, allowed: [.direct, .tunnel])
                        }
                        .padding(.vertical, Space.m).padding(.horizontal, Space.l)
                        .background(Palette.ground.color.opacity(0.5))
                    }
                }
                .scrollIndicators(.never)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: Activity and settings

public struct StatusScreen: View {
    let items: [ActivityItem]
    public init(items: [ActivityItem]) { self.items = items }
    public var body: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            PageHeader("Status") { EmptyView() }
            Panel {
                ForEach(Array(items.enumerated()), id: \.element.id) { i, a in
                    if i > 0 { Hairline() }
                    HStack(alignment: .firstTextBaseline, spacing: Space.l) {
                        Text(a.time).font(TypeScale.secondary).monospacedDigit().foregroundStyle(Palette.inkSecondary.color)
                            .frame(width: 44, alignment: .leading)
                        Text(a.text).font(TypeScale.body)
                            .foregroundStyle(a.isError ? Palette.danger.color : Palette.ink.color)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 10).padding(.horizontal, Space.l)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

public struct SettingsScreen: View {
    @State private var launch = true
    @State private var apply = true
    public init() {}

    func row<C: View>(_ title: String, _ note: String, @ViewBuilder _ control: () -> C) -> some View {
        HStack(spacing: Space.l) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(TypeScale.bodyStrong).foregroundStyle(Palette.ink.color)
                Text(note).font(TypeScale.secondary).foregroundStyle(Palette.inkSecondary.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Space.m)
            control()
        }
        .padding(.vertical, Space.m).padding(.horizontal, Space.l)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            PageHeader("Settings") { EmptyView() }
            Panel {
                row("Open at login", "Start the menu bar app when you sign in.") { Toggle("", isOn: $launch).labelsHidden().toggleStyle(.switch) }
                Hairline()
                row("Apply lists", "Turn off to send everything through the default route.") { Toggle("", isOn: $apply).labelsHidden().toggleStyle(.switch) }
                Hairline()
                row("List source", "Where ready-made lists are downloaded from.") {
                    Text("github.com/split-route/routing-rules").font(TypeScale.secondary).foregroundStyle(Palette.inkSecondary.color)
                }
            }
            Panel {
                row("Source code", "Split Route is open source under GPL-3.0.") {
                    Button("Open on GitHub") {}.buttonStyle(OutlineButtonStyle())
                }
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: Window and popover

public struct AppWindow: View {
    @State var page: Destination
    let tunnels: [TunnelItem]
    @State var lists: [ListItem]
    let activity: [ActivityItem]
    let focusFirstList: Bool

    public init(page: Destination, tunnels: [TunnelItem], lists: [ListItem], activity: [ActivityItem], focusFirstList: Bool = false) {
        self._page = State(initialValue: page); self.tunnels = tunnels; self._lists = State(initialValue: lists)
        self.activity = activity; self.focusFirstList = focusFirstList
    }

    public var body: some View {
        HStack(spacing: 0) {
            Sidebar(selection: $page, tunnels: tunnels)
            Group {
                switch page {
                case .home: TunnelsScreen(tunnels: tunnels)
                case .tunnels: TunnelsScreen(tunnels: tunnels)
                case .lists: ListsScreen(lists: $lists, tunnels: tunnels, focusFirst: focusFirstList)
                case .general, .application, .advanced: SettingsScreen()
                }
            }
            .padding(Space.xl)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Palette.ground.color)
        }
        .background(Palette.ground.color)
    }
}

public struct Popover: View {
    let tunnels: [TunnelItem]
    @State var lists: [ListItem]
    public init(tunnels: [TunnelItem], lists: [ListItem]) { self.tunnels = tunnels; self._lists = State(initialValue: lists) }

    public var body: some View {
        VStack(spacing: 0) {
            if tunnels.isEmpty {
                VStack(spacing: Space.s) {
                    Text("No servers yet").font(TypeScale.heading).foregroundStyle(Palette.ink.color)
                    Text("Add one to start routing.").font(TypeScale.secondary).foregroundStyle(Palette.inkSecondary.color)
                    Button("Add server") {}.buttonStyle(SolidButtonStyle()).padding(.top, 4)
                }.frame(maxWidth: .infinity).padding(.vertical, Space.xl)
            } else {
                ForEach(tunnels) { t in
                    HStack(spacing: Space.m) {
                        LineMark(state: t.state, line: t.line).frame(width: 56, height: 14)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(t.name).font(TypeScale.bodyStrong).foregroundStyle(Palette.ink.color).lineLimit(1)
                            Text(t.state.label).font(TypeScale.caption)
                                .foregroundStyle(t.state.isFailed ? Palette.danger.color : Palette.inkSecondary.color)
                        }
                        Spacer(minLength: Space.s)
                        Button(t.state.actionTitle) {}.buttonStyle(OutlineButtonStyle())
                    }
                    .padding(.horizontal, Space.l).padding(.vertical, 10)
                }
                Hairline()
                ForEach(Array(lists.prefix(4).enumerated()), id: \.element.id) { i, l in
                    HStack {
                        Text(l.name).font(TypeScale.body).foregroundStyle(Palette.ink.color).lineLimit(1)
                        Spacer(minLength: Space.s)
                        HStack(spacing: 6) {
                            Circle().fill(dot(l)).frame(width: 7, height: 7)
                            Text(label(l)).font(TypeScale.secondary).foregroundStyle(Palette.inkSecondary.color).lineLimit(1)
                        }
                    }
                    .padding(.horizontal, Space.l).padding(.vertical, 6)
                }
            }
            Hairline()
            HStack {
                Button("Open Split Route") {}.buttonStyle(.plain).font(TypeScale.bodyStrong).foregroundStyle(Palette.ink.color)
                Spacer()
                Button("Quit") {}.buttonStyle(.plain).font(TypeScale.body).foregroundStyle(Palette.inkSecondary.color)
            }
            .padding(.horizontal, Space.l).padding(.vertical, 10)
        }
        .frame(width: 340)
        .background(Palette.surface.color)
    }

    func dot(_ l: ListItem) -> Color {
        switch l.action {
        case .direct: return Palette.ink.color
        case .block: return Palette.danger.color
        case .tunnel: return (tunnels.first { $0.id == l.tunnelID } ?? tunnels.first)?.line.color ?? Palette.inkSecondary.color
        }
    }

    func label(_ l: ListItem) -> String {
        l.action == .tunnel ? ((tunnels.first { $0.id == l.tunnelID } ?? tunnels.first)?.name ?? "Server") : l.action.rawValue
    }
}

extension TunnelState {
    var isFailed: Bool { if case .failed = self { return true }; return false }
}
