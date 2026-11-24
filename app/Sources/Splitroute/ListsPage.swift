import Design
import SwiftUI

/// Every list the user has, in config order: ready-made (release) lists, URL
/// imports and custom lists. Each list goes direct, is blocked, or goes through a
/// tunnel; the tunnel is a colored chip, the same color as on the Tunnels page.
struct ListsPage: View {
    @EnvironmentObject private var model: AppModel
    /// Which page of this section is open instead of the lists: adding a list, or editing one.
    private enum Route: Equatable {
        case add(AddTab)
        case edit(CustomTarget)
        case editImport(RouteList)

        var key: String {
            switch self {
            case .add: return "add"
            case .edit(let t): return t.id.uuidString
            case .editImport(let l): return "import:" + l.name
            }
        }
    }

    @State private var route: Route?
    @State private var query = ""
    @State private var confirmRemove: RouteList?

    private var lists: [RouteList] { model.config?.lists ?? [] }

    /// The lists that match the search: by name, title (a ready-made list's own) or description.
    private var shown: [RouteList] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return lists }
        return lists.filter { l in
            let info = model.info(l.name)
            return [l.name, l.description ?? "", info?.title ?? "", info?.description ?? ""].contains { $0.localizedCaseInsensitiveContains(q) }
        }
    }

    var body: some View {
        // Adding and editing are pages of their own, not dialogs: the rule builder alone has too many fields for one.
        ZStack {
            if let r = route {
                subPage(r).transition(.opacity)
            } else {
                listPage.transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.18), value: route?.key)
    }

    private func subPage(_ r: Route) -> some View {
        let title: String
        switch r {
        case .add: title = "Add list"
        case .edit(let t): title = t.list.map { "Edit \($0.name)" } ?? "New list"
        case .editImport(let l): title = "Edit \(l.name)"
        }
        return VStack(alignment: .leading, spacing: 0) {
            Button { route = nil } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
                    Text("Routing").font(TypeScale.bodyStrong)
                }
                .foregroundStyle(Palette.inkSecondary.color)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, Space.xl).padding(.top, Space.xl)
            Text(title).font(TypeScale.title).foregroundStyle(Palette.ink.color).lineLimit(1)
                .padding(.horizontal, Space.xl).padding(.top, Space.s).padding(.bottom, Space.m)
            Group {
                switch r {
                case .add(let tab):
                    AddListPage(tab: tab)
                case .edit(let t):
                    CustomListEditor(original: t.list?.name, name: t.list?.name ?? "", action: t.list?.action ?? .direct,
                                     description: t.list?.description ?? "", rules: t.list?.rules ?? RuleSpec(), ruleSet: t.list?.ruleSet ?? false,
                                     takenNames: Set(lists.map(\.name)).subtracting([t.list?.name ?? ""]))
                case .editImport(let l):
                    EditImportView(list: l, takenNames: Set(lists.map(\.name)).subtracting([l.name]))
                }
            }
            .environment(\.closePage, { route = nil })
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var listPage: some View {
        PageScaffold("Routing") {
            if model.ready, !lists.isEmpty {
                Button("Add list") { route = .add(.ready) }.buttonStyle(SolidButtonStyle())
            }
        } content: {
            if !model.ready {
                ServiceUnavailable()
            } else if lists.isEmpty {
                routingSwitch
                Panel {
                    EmptyState(title: "Choose where traffic goes",
                               message: "A list is a set of sites or address ranges. Send each one direct, block it, or route it through a server.",
                               action: "Add a list") { route = .add(.ready) }
                }
            } else {
                VStack(alignment: .leading, spacing: Space.m) {
                    routingSwitch
                    SheetSearch(text: $query, prompt: "Search lists…")
                    if shown.isEmpty {
                        Text("No lists match.").font(TypeScale.body).foregroundStyle(Palette.inkSecondary.color)
                            .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, Space.xl)
                    }
                    Panel {
                        ForEach(Array(shown.enumerated()), id: \.element.id) { i, l in
                            if i > 0 { Hairline() }
                            row(l)
                        }
                    }
                    // Routing off: the lists stay but do nothing (and can't be touched); the default route below still works.
                    .opacity(model.routingOn ? 1 : 0.45)
                    .animation(.easeOut(duration: 0.2), value: model.routingOn)
                    .allowsHitTesting(model.routingOn)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.ready { finalBar }
        }
        .confirmationDialog("Delete \(confirmRemove?.name ?? "")?", isPresented: Binding(
            get: { confirmRemove != nil }, set: { if !$0 { confirmRemove = nil } }
        ), presenting: confirmRemove) { l in
            Button("Delete", role: .destructive) { Task { await model.removeList(l.name) } }
        } message: { l in
            Text("Its rules are deleted.")
        }
    }

    @ViewBuilder private func row(_ l: RouteList) -> some View {
        let st = model.status?.imports?.first { $0.name == l.name }
        let title = model.info(l.name)?.title ?? l.name
        let line = detail(l, st)
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(spacing: Space.l) {
                // Without a description the title is centered in the row, not pinned to its top.
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(TypeScale.bodyStrong).foregroundStyle(Palette.ink.color).lineLimit(1).help(title)
                    if !line.isEmpty {
                        Text(line).font(TypeScale.secondary).foregroundStyle(Palette.inkSecondary.color)
                            .monospacedDigit().lineLimit(2)
                    }
                }
                .layoutPriority(-1)
                Spacer(minLength: Space.m)
                downloadBadge(l, st)
                destinationMenu(l, title: title)
                infoMenu(l)
            }
            if model.vpnOn, l.action == .tunnel, let n = l.tunnel, !model.serverIsUp(n) {
                NoteLine(.error, "\(n) isn't connected, so this list is blocked until it is.")
            }
            if let e = model.error("list:\(l.name)") { NoteLine(.error, e) }
        }
        .padding(.vertical, Space.m).padding(.horizontal, Space.l)
    }

    /// The switch for every list at once. The default route is not part of it.
    private var routingSwitch: some View {
        Panel {
            FormRow("Routing", detail: model.routingOn ? "Each list sends its traffic direct, blocks it or routes it through a server."
                                                        : "Off: the lists do nothing. Only the default route is applied.",
                    error: model.error("routing")) {
                Toggle("Routing", isOn: Binding(get: { model.routingOn }, set: { on in Task { await model.setRoutingOn(on) } }))
                    .labelsHidden().toggleStyle(.switch).tint(Accent.color)
                    .accessibilityLabel("Routing")
            }
        }
    }

    /// Where traffic that matches no list goes. It stays at the bottom while the lists scroll.
    private var finalBar: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Panel {
                FormRow("Default Route", detail: "Traffic that matches no list") { DefaultRouteMenu() }
            }
            if model.vpnOn, case .tunnel(let n) = DefaultRouteMenu.current(model.config), !model.serverIsUp(n) {
                NoteLine(.error, "\(n) isn't connected, so the default route is blocked until it is.")
            }
            if let e = model.error("final") { NoteLine(.error, e) }
        }
        .padding(.horizontal, Space.xl).padding(.bottom, Space.l).padding(.top, Space.s)
    }

    /// What can be done with a list, by what kind it is: a custom list is edited or deleted; a list from a URL changes
    /// its address or description, updates or is deleted; a ready-made list updates or is deleted.
    private func infoMenu(_ l: RouteList) -> some View {
        Menu {
            if let when = updatedText(l) {
                Text(when) // a disabled line: when the list's entries last came in
                Divider()
            }
            if l.custom {
                Button("Edit List…") { route = .edit(CustomTarget(list: l)) }
                Divider()
                Button("Delete…", role: .destructive) {
                    if !l.rules.isEmpty || l.ruleSet { confirmRemove = l } else { Task { await model.removeList(l.name) } }
                }
            } else if l.importSource != nil {
                Button("Edit List…") { route = .editImport(l) }
                Button("Update Now") { Task { await model.refreshImport(l.name) } }
                Divider()
                Button("Delete", role: .destructive) { Task { await model.removeList(l.name) } }
            } else {
                Button("Update Now") { Task { await model.refreshRelease(l.name) } }
                Divider()
                Button("Delete", role: .destructive) { Task { await model.removeList(l.name) } }
            }
        } label: {
            Image(systemName: "info.circle").foregroundStyle(Palette.inkSecondary.color).contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel("Options for \(l.name)")
    }

    /// "Updated 13 seconds ago" for a list that is downloaded (a URL list or a ready-made one); nil for a custom list.
    private func updatedText(_ l: RouteList) -> String? {
        if l.custom { return nil }
        let date: Date?
        if l.importSource != nil {
            date = parseGoTime(model.status?.imports?.first { $0.name == l.name }?.fetchedAt)
        } else {
            date = model.files.releaseUpdated(l.name)
        }
        return date.map { "Updated \(relative($0))" } ?? "Not downloaded yet"
    }

    /// A progress ring with the percentage while the list downloads, a red icon (click to try again) when it failed.
    @ViewBuilder private func downloadBadge(_ l: RouteList, _ st: ImportStatus?) -> some View {
        switch model.downloads[l.name] ?? st?.error.map({ .failed($0) }) {
        case .running(let p):
            HStack(spacing: 6) {
                if let p { ProgressView(value: p).progressViewStyle(.circular).controlSize(.small) }
                else { ProgressView().controlSize(.small) }
                if let p { Text("\(Int(p * 100))%").font(TypeScale.secondary).monospacedDigit().foregroundStyle(Palette.inkSecondary.color) }
            }
            .help("Downloading \(l.name)")
        case .failed(let why):
            Button {
                if l.importSource != nil { Task { await model.refreshImport(l.name) } }
                else { Task { await model.refreshDownloads(force: true) } }
            } label: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.danger.color)
            }
            .buttonStyle(.plain)
            .help("Download failed: \(why). Click to try again.")
            .accessibilityLabel("Download of \(l.name) failed, try again")
        case nil:
            EmptyView()
        }
    }

    private func destinationMenu(_ l: RouteList, title: String) -> some View {
        let current = RouteDestination(l)
        let names = model.tunnels.map(\.name)
        let named = l.tunnel.map { n in names.contains(n) ? names : names + [n] } ?? names // a missing tunnel stays an option
        let options: [RouteDestination] = [.none, .direct, .block, .selected] + named.map(RouteDestination.tunnel)
        return SelectMenu(title: current.label, options: options, label: \.label, selected: current, dot: \.dot, group: \.group) { d in
            guard d != current else { return }
            Task {
                switch d {
                case .none: await model.setAction(l.name, .none)
                case .direct: await model.setAction(l.name, .direct)
                case .block: await model.setAction(l.name, .block)
                case .selected: await model.setAction(l.name, .tunnel, tunnel: nil)
                case .tunnel(let n): await model.setAction(l.name, .tunnel, tunnel: n)
                }
            }
        }
        .accessibilityLabel("Action for \(title)")
    }

    /// The second line: the list's description, if it has one. Nothing else (the update time is in the info menu).
    private func detail(_ l: RouteList, _ st: ImportStatus?) -> String {
        if let d = l.description { return d }
        if l.custom || l.importSource != nil { return "" }
        return model.info(l.name)?.description ?? ""
    }

}

/// "1,234 entries", or nothing when the list has none.
@MainActor func entriesLine(_ model: AppModel, _ name: String) -> String? {
    guard let n = model.status?.lists.first(where: { $0.name == name })?.entries, n > 0 else { return nil }
    return plural(n, "entry", "entries")
}

/// Where traffic goes: nowhere (a list kept but not applied), direct, blocked, through the active server, or through one named.
enum RouteDestination: Hashable {
    case none, direct, block, selected, tunnel(String)

    init(_ l: RouteList) {
        switch l.action {
        case .none: self = .none
        case .direct: self = .direct
        case .block: self = .block
        case .tunnel: self = l.tunnel.map(RouteDestination.tunnel) ?? .selected
        }
    }

    var label: String {
        switch self {
        case .none: return "No Action"
        case .direct: return "Direct"
        case .block: return "Block"
        case .selected: return "Active Server"
        case .tunnel(let n): return n
        }
    }

    /// The named servers sit under a "Servers" title.
    var group: String? {
        if case .tunnel = self { return "Servers" }
        return nil
    }

    var dot: Color {
        switch self {
        case .none: return Palette.inkSecondary.color.opacity(0.5)
        case .direct: return Palette.success.color
        case .block: return Palette.danger.color
        case .selected, .tunnel: return Accent.color
        }
    }
}

/// The dropdown for the default route: used on the Routing page and in the menu bar.
struct DefaultRouteMenu: View {
    @EnvironmentObject private var model: AppModel
    /// How wide the chosen name may get before it is cut with …
    var maxTitleWidth: CGFloat? = 200

    /// What the stored default route is, as a destination.
    static func current(_ cfg: Config?) -> RouteDestination {
        switch cfg?.finalAction ?? .tunnel {
        case .direct: return .direct
        case .block: return .block
        default: return cfg?.finalTunnel.map(RouteDestination.tunnel) ?? .selected
        }
    }

    var body: some View {
        let current = Self.current(model.config)
        let names = model.tunnels.map(\.name)
        let named = model.config?.finalTunnel.map { n in names.contains(n) ? names : names + [n] } ?? names
        SelectMenu(title: current.label, options: [.direct, .block, .selected] + named.map(RouteDestination.tunnel),
                   label: \.label, selected: current, dot: \.dot, group: \.group, maxTitleWidth: maxTitleWidth) { d in
            guard d != current else { return }
            Task {
                switch d {
                case .direct: await model.setFinal(.direct)
                case .block: await model.setFinal(.block)
                case .selected, .none: await model.setFinal(.tunnel)
                case .tunnel(let n): await model.setFinal(.tunnel, tunnel: n)
                }
            }
        }
        .accessibilityLabel("Default route")
    }
}
