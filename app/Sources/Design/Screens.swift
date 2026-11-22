import SwiftUI

public enum Destination: String, CaseIterable, Sendable {
    case tunnels = "Tunnels", lists = "Lists", status = "Status", settings = "Settings"
}

// MARK: Sidebar

public struct Sidebar: View {
    @Binding var selection: Destination
    let tunnels: [TunnelItem]
    /// Space above the title for the window's traffic lights.
    let topInset: CGFloat
    let title: String
    /// Tunnels that exist but aren't listed (the list shows only those that are on).
    let moreCount: Int
    /// One line about the VPN at the foot of the sidebar (a dot, filled when it is on), or nil.
    let status: String?
    let statusOn: Bool
    public init(selection: Binding<Destination>, tunnels: [TunnelItem], title: String = "Split Route", topInset: CGFloat = 0,
                moreCount: Int = 0, status: String? = nil, statusOn: Bool = false) {
        self._selection = selection; self.tunnels = tunnels; self.title = title; self.topInset = topInset; self.moreCount = moreCount
        self.status = status; self.statusOn = statusOn
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(TypeScale.heading).foregroundStyle(Palette.ink.color)
                .padding(.horizontal, Space.m).padding(.top, topInset).padding(.bottom, Space.xl)
            ForEach(Destination.allCases, id: \.self) { d in
                Button { selection = d } label: {
                    HStack(spacing: Space.s) {
                        RoundedRectangle(cornerRadius: 1.5).fill(selection == d ? Palette.ink.color : .clear).frame(width: 3, height: 18)
                        Text(d.rawValue).font(selection == d ? TypeScale.sidebarStrong : TypeScale.sidebar)
                        Spacer()
                    }
                    .foregroundStyle(selection == d ? Palette.ink.color : Palette.inkSecondary.color)
                    .padding(.vertical, 11).padding(.horizontal, Space.s)
                    .background(selection == d ? Palette.surface.color : .clear, in: RoundedRectangle(cornerRadius: Radius.control))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == d ? .isSelected : [])
            }
            Spacer()
            if let status {
                HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                    Circle().fill(statusOn ? Palette.ink.color : .clear)
                        .overlay(Circle().stroke(Palette.inkSecondary.color, lineWidth: statusOn ? 0 : 1.5))
                        .frame(width: 8, height: 8)
                    Text(status).font(TypeScale.secondary).foregroundStyle(Palette.inkSecondary.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
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
        .frame(width: 200)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(Palette.ground.color)
    }

    static func summary(_ t: [TunnelItem]) -> String {
        let on = t.filter { $0.state == .connected }.count
        return on == 0 ? "No tunnel connected" : "\(on) of \(t.count) tunnels connected"
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

    var summary: String {
        if tunnels.isEmpty { return "No tunnels yet." }
        let on = tunnels.filter { $0.state == .connected }.map(\.name)
        let needs = tunnels.filter { $0.state == .needsAuth }.map(\.name)
        var parts: [String] = []
        if !on.isEmpty { parts.append("\(on.joined(separator: " and ")) \(on.count == 1 ? "is" : "are") connected.") }
        if !needs.isEmpty { parts.append("\(needs.joined(separator: " and ")) needs your sign-in.") }
        return parts.isEmpty ? "No tunnel is connected." : parts.joined(separator: " ")
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            PageHeader("Tunnels", summary: summary) {
                if !tunnels.isEmpty { Button("Add tunnel") {}.buttonStyle(SolidButtonStyle()) }
            }
            if tunnels.isEmpty {
                Panel { EmptyState(title: "Add your first tunnel",
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
                            TunnelChip(name: tunnel?.name ?? "No tunnel", line: tunnel?.line ?? .cobalt)
                            Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(Palette.inkSecondary.color)
                        }
                    }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
                    .accessibilityLabel("Tunnel for \(item.name)")
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

    var summary: String {
        if lists.isEmpty { return "No lists yet." }
        let n = lists.count
        let rest = defaultTunnel.map { "Everything else goes through \($0.name)." } ?? "Everything else goes direct."
        return "\(n) \(n == 1 ? "list" : "lists"). \(rest)"
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            PageHeader("Lists", summary: summary) {
                if !lists.isEmpty { Button("Add list") {}.buttonStyle(SolidButtonStyle()) }
            }
            if lists.isEmpty {
                Panel { EmptyState(title: "Choose where traffic goes",
                                   message: "A list is a set of sites or address ranges. Send each one direct, block it, or route it through a tunnel.",
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
                            Text("Everything else").font(TypeScale.bodyStrong).foregroundStyle(Palette.ink.color)
                            Spacer()
                            ActionChoice(listName: "everything else", selection: $rest,
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
            PageHeader("Status", summary: "What the service did, newest first.") { EmptyView() }
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
            PageHeader("Settings", summary: "Version 0.1.0") { EmptyView() }
            Panel {
                row("Open at login", "Start the menu bar app when you sign in.") { Toggle("", isOn: $launch).labelsHidden().toggleStyle(.switch) }
                Hairline()
                row("Apply lists", "Turn off to send everything through the default route.") { Toggle("", isOn: $apply).labelsHidden().toggleStyle(.switch) }
                Hairline()
                row("List source", "Where ready-made lists are downloaded from.") {
                    Text("github.com/aliraghebi/routing-rules").font(TypeScale.secondary).foregroundStyle(Palette.inkSecondary.color)
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
                case .tunnels: TunnelsScreen(tunnels: tunnels)
                case .lists: ListsScreen(lists: $lists, tunnels: tunnels, focusFirst: focusFirstList)
                case .status: StatusScreen(items: activity)
                case .settings: SettingsScreen()
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
                    Text("No tunnels yet").font(TypeScale.heading).foregroundStyle(Palette.ink.color)
                    Text("Add one to start routing.").font(TypeScale.secondary).foregroundStyle(Palette.inkSecondary.color)
                    Button("Add tunnel") {}.buttonStyle(SolidButtonStyle()).padding(.top, 4)
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
        l.action == .tunnel ? ((tunnels.first { $0.id == l.tunnelID } ?? tunnels.first)?.name ?? "Tunnel") : l.action.rawValue
    }
}

extension TunnelState {
    var isFailed: Bool { if case .failed = self { return true }; return false }
}
