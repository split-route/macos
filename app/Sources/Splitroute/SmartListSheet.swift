import Design
import SwiftUI

/// A custom list: its name and the proxy servers in it (no limit). Saved only with Save; a new list becomes the one Smart
/// Select uses.
struct SmartListSheet: View {
    enum Mode: Identifiable {
        case new, edit(UUID)
        var id: String { if case .edit(let i) = self { return i.uuidString }; return "new" }
    }

    let mode: Mode
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var chosen: Set<Int64> = []
    @State private var query = ""
    @State private var error: String?

    private var servers: [AppModel.SmartServer] { model.smartServers() }

    /// The servers that match the search, in groups in the order they come (hand-added servers are one group).
    private var groups: [(title: String, servers: [AppModel.SmartServer])] {
        var order: [String] = []
        var by: [String: [AppModel.SmartServer]] = [:]
        for s in servers where Highlight.matches("\(s.name) \(s.group ?? "")", query) {
            let title = s.group ?? AppModel.handAddedTitle
            if by[title] == nil { order.append(title) }
            by[title, default: []].append(s)
        }
        return order.map { ($0, by[$0] ?? []) }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Space.s) {
                Text(isNew ? "New list" : "Edit list").font(TypeScale.bodyStrong)
                TextField("List name", text: $name, prompt: Text("Fast ones").foregroundColor(.secondary))
                    .labelsHidden().textFieldStyle(.plain).multilineTextAlignment(.leading).fieldBox()
                Text("\(chosen.count) chosen. OpenVPN servers aren't listed.")
                    .font(TypeScale.secondary).foregroundStyle(Palette.inkSecondary.color)
                SheetSearch(text: $query, prompt: "Search servers…").padding(.top, Space.m)
            }
            .padding(.horizontal, Space.xl).padding(.top, Space.xl).padding(.bottom, Space.s)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(groups, id: \.title) { g in
                        Text(g.title).font(TypeScale.secondary.weight(.semibold)).foregroundStyle(Palette.inkSecondary.color)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, Space.m).padding(.top, Space.m).padding(.bottom, 2)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(g.servers) { s in row(s) }
                    }
                    if groups.isEmpty {
                        Text(servers.isEmpty ? "No proxy servers." : "No servers match.").font(TypeScale.body)
                            .foregroundStyle(Palette.inkSecondary.color).padding(Space.xl)
                    }
                }
                .padding(.horizontal, Space.m)
            }
            .scrollIndicators(.never)
            SheetButtons(error: error) {
                Button("Clear") { chosen = [] }.buttonStyle(OutlineButtonStyle()).disabled(chosen.isEmpty)
                Button("Cancel", role: .cancel) { dismiss() }.buttonStyle(OutlineButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Save", action: save).buttonStyle(SolidButtonStyle()).keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || chosen.isEmpty)
            }
        }
        .frame(width: 520, height: 600)
        .onAppear(perform: load)
    }

    private var isNew: Bool { if case .new = mode { return true }; return false }

    private func load() {
        guard case .edit(let id) = mode, let l = SmartLists.load().first(where: { $0.id == id }) else { return }
        name = l.name
        chosen = Set(l.servers)
    }

    private func save() {
        var lists = SmartLists.load()
        let id: UUID? = { if case .edit(let i) = mode { return i }; return nil }()
        do {
            let clean = try SmartLists.validName(name, among: lists, excluding: id)
            let servers = servers.map(\.id).filter(chosen.contains) // in the order of the list of servers
            if let id, let i = lists.firstIndex(where: { $0.id == id }) {
                lists[i].name = clean
                lists[i].servers = servers
            } else {
                let l = SmartList(name: clean, servers: servers)
                lists.append(l)
                UserDefaults.standard.set(SmartLists.scopeValue(l.id), forKey: Prefs.smartScope)
            }
            SmartLists.save(lists)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }

    private func row(_ s: AppModel.SmartServer) -> some View {
        let on = chosen.contains(s.id)
        return Button {
            if on { chosen.remove(s.id) } else { chosen.insert(s.id) }
        } label: {
            HStack(spacing: Space.m) {
                Image(systemName: on ? "checkmark.circle.fill" : "circle").font(.system(size: 16))
                    .foregroundStyle(on ? Accent.color : Palette.inkSecondary.color)
                Text(Highlight.attributed((Flags.prefix(name: s.name, country: s.country).map { $0 + " " } ?? "") + s.name, query))
                    .font(TypeScale.body).foregroundStyle(Palette.ink.color).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.vertical, Space.s).padding(.horizontal, Space.m)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(s.name)
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }
}

/// Where Smart Select looks for a better server: every server, the active server's group, or one of the custom lists (each with
/// edit and delete buttons), and New List….
struct SmartScopeMenu: View {
    enum Choice: Hashable { case all, group, list(UUID), new }

    @EnvironmentObject private var model: AppModel
    @AppStorage(Prefs.smartScope) private var scope = "all"
    @AppStorage(Prefs.smartLists) private var listsData = Data()
    @State private var sheet: SmartListSheet.Mode?
    @State private var deleting: SmartList?

    private var lists: [SmartList] { SmartLists.decode(listsData) }

    private var selected: Choice {
        if scope == "group" { return .group }
        if let id = SmartLists.listID(in: scope), lists.contains(where: { $0.id == id }) { return .list(id) }
        return .all
    }

    private func label(_ c: Choice) -> String {
        switch c {
        case .all: return "All servers"
        case .group: return "Active server's group"
        case .list(let id): return lists.first { $0.id == id }?.name ?? "List"
        case .new: return "New List…"
        }
    }

    private func iconButton(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.ink.color).roundGlass(24)
        }
        .buttonStyle(.plain).help(help).accessibilityLabel(help)
    }

    var body: some View {
        SelectMenu(title: label(selected), options: [.all, .group] + lists.map { Choice.list($0.id) } + [.new], label: label, selected: selected,
                   dot: { $0 == selected ? Accent.color : .clear },
                   group: { c in if case .list = c { return "Custom lists" } else if c == .new { return "Custom lists" } else { return nil } },
                   maxTitleWidth: 150, compact: true, checkmark: false, titleDot: false, symbol: { $0 == .new ? "plus" : nil },
                   accessory: { c, close in
                       guard case .list(let id) = c, let l = lists.first(where: { $0.id == id }) else { return nil }
                       return AnyView(HStack(spacing: 4) {
                           iconButton("pencil", "Edit “\(l.name)”") { close(); sheet = .edit(id) }
                           iconButton("trash", "Delete “\(l.name)”") { close(); deleting = l }
                       })
                   }) { c in
            switch c {
            case .all: scope = "all"
            case .group: scope = "group"
            case .list(let id): scope = SmartLists.scopeValue(id)
            case .new: sheet = .new
            }
        }
        .sheet(item: $sheet) { mode in SmartListSheet(mode: mode).environmentObject(model).glassSheet() }
        .confirmationDialog("Delete the list “\(deleting?.name ?? "")”?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            presenting: deleting) { l in
            Button("Delete", role: .destructive) {
                SmartLists.save(lists.filter { $0.id != l.id })
                if SmartLists.listID(in: scope) == l.id { scope = "all" }
            }
        } message: { _ in
            Text("The servers stay; only the list goes.")
        }
        .help("Where Smart Select looks for a better server")
        .accessibilityLabel("Smart Select servers")
    }
}
