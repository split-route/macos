import SwiftUI

/// Every list the user has, in config order: ready-made (release) lists, URL
/// imports and custom lists. The + in the toolbar opens AddListSheet.
struct ListsPage: View {
    @EnvironmentObject private var model: AppModel
    @State private var adding = false
    @State private var editing: CustomTarget?
    @State private var confirmRemove: RouteList?

    private var lists: [RouteList] { model.config?.lists ?? [] }

    var body: some View {
        Group {
            if !model.ready {
                Form { ServiceUnavailable() }
            } else if lists.isEmpty {
                // In a scroll view like the other pages, so the toolbar looks the same.
                GeometryReader { g in
                    ScrollView {
                        EmptyLists { adding = true }.frame(maxWidth: .infinity, minHeight: g.size.height)
                    }
                }
            } else {
                Form {
                    Section {
                        ForEach(lists) { row($0) }
                    } footer: {
                        ActionsFooter()
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { adding = true } label: { Image(systemName: "plus") }
                    .help("Add List")
                    .accessibilityLabel("Add List")
                    .disabled(!model.ready)
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

    @ViewBuilder private func row(_ l: RouteList) -> some View {
        let st = model.status?.imports?.first { $0.name == l.name }
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: symbol(l))
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .help(kind(l))
            VStack(alignment: .leading, spacing: 2) {
                Text(model.info(l.name)?.title ?? l.name)
                Text(detail(l, st))
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let e = model.error("list:\(l.name)") { ErrorText(e) }
                if let e = st?.error { WarningText("Last download failed: \(e)") }
            }
            Spacer(minLength: 12)
            ActionPicker(action: l.action, tunnel: l.tunnel, tunnels: model.tunnels.map(\.name)) { a, t in
                Task { await model.setAction(l.name, a, tunnel: t) }
            }
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
        .padding(.vertical, 4)
    }

    private func symbol(_ l: RouteList) -> String {
        if l.importSource != nil { return "link" }
        return l.custom ? "doc.text" : "globe"
    }

    private func kind(_ l: RouteList) -> String {
        if l.importSource != nil { return "Imported from a URL, downloaded daily" }
        return l.custom ? "Your own list" : "Ready-made list, updated daily"
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
            parts.append(plural(entryCount(l), "entry", "entries"))
        } else {
            parts.append(model.info(l.name)?.description ?? "Ready-made list")
        }
        if let r = entriesLine(model, l.name) { parts.append(r) }
        return parts.joined(separator: " · ")
    }

    private func entryCount(_ l: RouteList) -> Int {
        l.entries.filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }.count
    }
}

/// Shown instead of the table when there are no lists, like Raycast's empty pages.
private struct EmptyLists: View {
    let add: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "list.bullet.rectangle")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)
            Text("No lists yet").font(.title3.weight(.semibold))
            Text("Add a ready-made list, import one from a URL or a file, or create your own. Without lists all traffic goes through the default tunnel, the first one connected.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 360)
            Button("Add List", action: add)
                .controlSize(.large)
                .padding(.top, 4)
        }
        .padding(32)
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
