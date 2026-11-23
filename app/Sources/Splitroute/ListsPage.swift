import Design
import SwiftUI

/// Every list the user has, in config order: ready-made (release) lists, URL
/// imports and custom lists. Each list goes direct, is blocked, or goes through a
/// tunnel; the tunnel is a colored chip, the same color as on the Tunnels page.
struct ListsPage: View {
    @EnvironmentObject private var model: AppModel
    @State private var adding = false
    @State private var editing: CustomTarget?
    @State private var confirmRemove: RouteList?

    private var lists: [RouteList] { model.config?.lists ?? [] }

    private var summary: String {
        if !model.ready { return "The service isn't running." }
        if lists.isEmpty { return "No lists yet." }
        let rest: String
        if !model.vpnOn { rest = "The VPN is off, so lists have no effect." }
        else if let t = model.selectedTunnel { rest = "Everything else goes through \(t.name)." }
        else { rest = "No tunnel is selected." }
        return "\(plural(lists.count, "list")). \(rest)"
    }

    var body: some View {
        PageScaffold("Routing", summary: summary) {
            if model.ready, !lists.isEmpty {
                Button("Add list") { adding = true }.buttonStyle(SolidButtonStyle())
            }
        } content: {
            if !model.ready {
                ServiceUnavailable()
            } else if lists.isEmpty {
                Panel {
                    EmptyState(title: "Choose where traffic goes",
                               message: "A list is a set of sites or address ranges. Send each one direct, block it, or route it through a tunnel.",
                               action: "Add a list") { adding = true }
                }
            } else {
                VStack(alignment: .leading, spacing: Space.m) {
                    Panel {
                        ForEach(Array(lists.enumerated()), id: \.element.id) { i, l in
                            if i > 0 { Hairline() }
                            row(l)
                        }
                    }
                    Text("Direct skips every tunnel. Block drops the traffic. Tunnel sends it through the selected tunnel or the one you pick. Changes apply right away, without reconnecting, unless a list is added, removed or moved to another tunnel.")
                        .font(TypeScale.secondary).foregroundStyle(Palette.inkSecondary.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .sheet(isPresented: $adding) {
            AddListSheet().environmentObject(model)
        }
        .sheet(item: $editing) { t in
            CustomListEditor(original: t.list?.name, name: t.list?.name ?? "", action: t.list?.action ?? .direct,
                             text: (t.list?.entries ?? []).joined(separator: "\n"),
                             takenNames: Set(lists.map(\.name)).subtracting([t.list?.name ?? ""]))
                .environmentObject(model)
                .frame(width: 560, height: 512)
        }
        .confirmationDialog("Remove \(confirmRemove?.name ?? "")?", isPresented: Binding(
            get: { confirmRemove != nil }, set: { if !$0 { confirmRemove = nil } }
        ), presenting: confirmRemove) { l in
            Button("Remove", role: .destructive) { Task { await model.removeList(l.name) } }
        } message: { l in
            Text("Its \(plural(entryCount(l), "entry", "entries")) are deleted. Export the settings first (splitroute config export) to keep a copy.")
        }
    }

    private func designAction(_ a: Action) -> ListAction {
        switch a {
        case .direct: return .direct
        case .block: return .block
        case .tunnel: return .tunnel
        }
    }

    private func appAction(_ a: ListAction) -> Action {
        switch a {
        case .direct: return .direct
        case .block: return .block
        case .tunnel: return .tunnel
        }
    }

    @ViewBuilder private func row(_ l: RouteList) -> some View {
        let st = model.status?.imports?.first { $0.name == l.name }
        let title = model.info(l.name)?.title ?? l.name
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(spacing: Space.l) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(TypeScale.bodyStrong).foregroundStyle(Palette.ink.color).lineLimit(1).help(title)
                    Text(detail(l, st)).font(TypeScale.secondary).foregroundStyle(Palette.inkSecondary.color)
                        .monospacedDigit().lineLimit(2)
                }
                .layoutPriority(-1)
                Spacer(minLength: Space.m)
                if l.action == .tunnel { tunnelMenu(l, title: title) }
                ActionChoice(listName: title,
                             selection: Binding(get: { designAction(l.action) },
                                                set: { a in
                                                    guard a != designAction(l.action) else { return }
                                                    Task { await model.setAction(l.name, appAction(a), tunnel: nil) }
                                                }),
                             tunnelLine: nil)
                if l.custom {
                    RowButton(symbol: "pencil", help: "Edit \(l.name)") { editing = CustomTarget(list: l) }
                }
                if l.importSource != nil {
                    RowButton(symbol: "arrow.clockwise", help: "Download \(l.name) again") {
                        Task { await model.refreshImport(l.name) }
                    }
                }
                RowButton(symbol: "minus.circle", help: "Remove \(l.name)") {
                    if l.custom && entryCount(l) > 0 { confirmRemove = l } else { Task { await model.removeList(l.name) } }
                }
            }
            if l.action == .tunnel, let n = l.tunnel, model.tunnels.first(where: { $0.name == n })?.state != .connected {
                NoteLine(.error, "\(n) isn't connected, so this list is blocked until it is.")
            }
            if let e = model.error("list:\(l.name)") { NoteLine(.error, e) }
            if let e = st?.error { NoteLine(.warning, "Last download failed: \(e)") }
        }
        .padding(.vertical, Space.m).padding(.horizontal, Space.l)
    }

    /// Which tunnel a Tunnel list uses: the selected one, or a named one.
    private func tunnelMenu(_ l: RouteList, title: String) -> some View {
        let names = model.tunnels.map(\.name)
        let options = l.tunnel.map { n in names.contains(n) ? names : names + [n] } ?? names
        return Menu {
            Button("Selected tunnel") { Task { await model.setAction(l.name, .tunnel, tunnel: nil) } }
            ForEach(options, id: \.self) { n in
                Button(n) { Task { await model.setAction(l.name, .tunnel, tunnel: n) } }
            }
        } label: {
            HStack(spacing: 4) {
                DestinationLabel(l.tunnel ?? "Selected tunnel", color: Palette.inkSecondary.color)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Palette.inkSecondary.color)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        .accessibilityLabel("Tunnel for \(title)")
    }

    /// The second line: what the list is, then how many routes it applied.
    private func detail(_ l: RouteList, _ st: ImportStatus?) -> String {
        var parts: [String] = []
        if let src = l.importSource {
            parts.append(URLComponents(string: src.url)?.host ?? src.url)
            if let st {
                parts.append(parseGoTime(st.fetchedAt).map { "\(plural(st.entries, "entry", "entries")), downloaded \(relative($0))" }
                    ?? "Not downloaded yet")
            }
        } else if l.custom {
            // The applied count (below) says the same; show the stored count until the service reports one.
            if entriesLine(model, l.name) == nil { parts.append(plural(entryCount(l), "entry", "entries")) }
        } else {
            parts.append(model.info(l.name)?.description ?? "Ready-made list")
        }
        // An import's status line already has its count; a custom list's was handled above.
        if !l.custom, st == nil, let r = entriesLine(model, l.name) { parts.append(r) }
        return parts.joined(separator: ", ")
    }

    private func entryCount(_ l: RouteList) -> Int {
        l.entries.filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }.count
    }
}

/// "1,234 entries", or nothing when the list has none.
@MainActor func entriesLine(_ model: AppModel, _ name: String) -> String? {
    guard let n = model.status?.lists.first(where: { $0.name == name })?.entries, n > 0 else { return nil }
    return plural(n, "entry", "entries")
}

struct ActionsFooter: View {
    var body: some View {
        Text("Direct: through your normal connection, outside any tunnel. Block: dropped. Tunnel: through a tunnel (the default one, the first connected, or the one you pick). Changes apply right away. Changes reach a connected tunnel without reconnecting it, unless a list is added, removed or points somewhere else.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
