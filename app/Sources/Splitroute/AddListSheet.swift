import Design
import SwiftUI
import UniformTypeIdentifiers

/// The four ways to add a list, opened from the Lists page's + button.
enum AddTab: String, CaseIterable, Identifiable {
    case ready = "Ready-made", url = "From URL", file = "From File", custom = "Custom"
    var id: String { rawValue }
}

struct AddListSheet: View {
    @EnvironmentObject private var model: AppModel
    @State private var tab: AddTab = .ready

    private var taken: Set<String> { Set((model.config?.lists ?? []).map(\.name)) }

    var body: some View {
        VStack(spacing: 0) {
            SheetTabs(options: AddTab.allCases, selection: $tab)
                .padding(.top, Space.l)
                .padding(.bottom, Space.s)
            switch tab {
            case .ready: ReadyListsTab()
            case .url: ImportEditor(takenNames: taken)
            case .file: FileImportTab(takenNames: taken)
            case .custom: CustomListEditor(original: nil, name: "", action: .direct, description: "", text: "", takenNames: taken)
            }
        }
        .sheetBackground()
        // Fits under the toolbar of the 580 pt window.
        .frame(width: 560, height: 512)
    }
}

/// Release lists not added yet, by title. Adding keeps the sheet open, so
/// several can be added in a row; each shows on the page at once, downloading.
struct ReadyListsTab: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var actions: [String: Action] = [:] // changed before adding

    private var missing: [ListInfo] {
        let added = Set((model.config?.lists ?? []).map(\.name))
        let q = query.trimmingCharacters(in: .whitespaces)
        return model.available.filter { !added.contains($0) }
            .map { model.info($0) ?? ListInfo(name: $0, title: $0, description: "", action: .direct) }
            .filter { q.isEmpty || "\($0.title) \($0.description) \($0.name)".localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetSearch(text: $query, prompt: "Search lists…")
                .padding(.horizontal, Space.xl).padding(.vertical, Space.s)
                // Don't start in the search field (the sheet would focus it); click to search.
                .onAppear { DispatchQueue.main.async { NSApp.keyWindow?.makeFirstResponder(nil) } }
            ScrollView {
                VStack(alignment: .leading, spacing: Space.m) {
                    if model.available.isEmpty {
                        SheetNote("Can't reach the list server to see which lists it has.")
                    } else if missing.isEmpty {
                        SheetNote(query.isEmpty ? "Every ready-made list is added." : "No lists match.")
                    } else {
                        Panel {
                            ForEach(Array(missing.enumerated()), id: \.element.id) { n, i in
                                if n > 0 { Hairline() }
                                let action = actions[i.name] ?? i.action
                                FormRow(i.title, detail: i.description) {
                                    SelectMenu(title: action.menuLabel, options: Action.allCases, label: \.menuLabel, selected: action, dot: \.dot) {
                                        actions[i.name] = $0 // pick the tunnel on the Routing page
                                    }
                                    Button("Add") { Task { await model.enableRelease(i.name, action) } }
                                        .buttonStyle(OutlineButtonStyle()).disabled(model.busy)
                                }
                            }
                        }
                    }
                    SheetNote("No Action keeps a list without applying it. Direct skips every server. Block drops the traffic. Active Server sends it through the server you're connected with. Changes apply right away.")
                }
                .padding(.horizontal, Space.xl).padding(.vertical, Space.s)
            }
            .scrollIndicators(.never)
            SheetBar(error: model.error("lists")) {
                SheetButton(title: "Done", primary: true) { dismiss() }
            }
        }
    }
}

/// Creates a custom list from a file on this Mac. The app reads the file and
/// sends its text; the service parses it like an import.
struct FileImportTab: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let takenNames: Set<String>
    @State private var file: URL?
    @State private var text: String?
    @State private var binary: Data? // a sing-box rule-set (.srs)
    @State private var name = ""
    @State private var action: Action = .block
    @State private var description = ""
    @State private var choosing = false
    @State private var error: String?
    @State private var done: EntryEdit?

    /// The service takes requests up to 8 MiB; leave room for JSON escaping (and base64 for a binary list).
    private static let maxBytes = 5 << 20

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    private var problem: String? {
        if (text == nil && binary == nil) || trimmedName.isEmpty { return "" }
        if trimmedName.count > 64 { return "Use at most 64 characters for the name." }
        if takenNames.contains(trimmedName) { return "Another list already has this name." }
        if description.count > Config.maxDescription { return "Use at most \(Config.maxDescription) characters for the description." }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.m) {
                    Panel {
                        FormRow(file?.lastPathComponent ?? "No file chosen",
                                detail: binary != nil ? "sing-box rule-set" : text.map { plural($0.split(whereSeparator: \.isNewline).count, "line") }) {
                            Button("Choose File…") { choosing = true }.buttonStyle(OutlineButtonStyle())
                        }
                        Hairline()
                        FieldRow(title: "Name", text: $name)
                        Hairline()
                        FieldRow(title: "Description", text: $description, prompt: "Optional")
                        Hairline()
                        ActionRow(action: $action)
                    }
                    .disabled(done != nil)
                    SheetNote("Plain lists (one address, range, domain or AS number per line), hosts files, Surge/Clash domain sets and sing-box rule-sets (.srs), up to 5 MB. Lines that aren't entries are skipped. The entries are copied into a custom list you can edit; for a list that changes, use From URL so it stays up to date.")
                }
                .padding(.horizontal, Space.xl).padding(.vertical, Space.s)
            }
            .scrollIndicators(.never)
            SheetBar(error: error ?? problem, success: done.map(summary)) {
                if done != nil {
                    SheetButton(title: "Done", primary: true) { dismiss() }
                } else {
                    SheetButton(title: "Cancel") { dismiss() }
                    SheetButton(title: "Import", primary: true, disabled: problem != nil || model.busy) { Task { await importFile() } }
                }
            }
        }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.plainText, .data]) { result in
            switch result {
            case .success(let url): load(url)
            case .failure(let e): error = e.localizedDescription
            }
        }
    }

    private func load(_ url: URL) {
        error = nil
        text = nil
        binary = nil
        file = url
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= Self.maxBytes else {
            error = "This file is \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)); the limit is 5 MB. Put it online and use From URL instead."
            return
        }
        guard let data = try? Data(contentsOf: url) else {
            error = "This file can't be read."
            return
        }
        if Daemon.isRuleSet(data) {
            binary = data
        } else if let s = String(data: data, encoding: .utf8) {
            text = s
        } else {
            error = "This isn't a text file (UTF-8) or a sing-box rule-set (.srs)."
            return
        }
        if trimmedName.isEmpty { name = url.deletingPathExtension().lastPathComponent }
    }

    private func importFile() async {
        guard text != nil || binary != nil else { return }
        let r = await model.createFromFile(name: trimmedName, action: action, text: text ?? "", binary: binary, description: description.trimmingCharacters(in: .whitespaces))
        error = r.error
        if r.error == nil { done = r.edit ?? EntryEdit() }
    }

    private func summary(_ e: EntryEdit) -> String {
        var s = "Added \(plural(e.added ?? 0, "entry", "entries")) to \(trimmedName)."
        if let n = e.skipped, n > 0 { s += " \(plural(n, "line")) skipped." }
        return s
    }
}

/// The bottom bar of a sheet: an error or success line, then the buttons.
struct SheetButtons<Buttons: View>: View {
    var error: String?
    var success: String?
    @ViewBuilder let buttons: Buttons

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error, !error.isEmpty { ErrorText(error) }
            if let success { Label(success, systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
            HStack {
                Spacer()
                buttons
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 16)
    }
}

struct CustomTarget: Identifiable {
    let id = UUID()
    let list: RouteList? // nil: a new list
}

/// Creates or edits a custom list. Saving sends the changes to the service and
/// closes only when it accepted them; its error stays in the sheet.
struct CustomListEditor: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State var original: String?
    @State var name: String
    @State var action: Action
    @State var description: String
    @State var text: String
    let takenNames: Set<String>
    @State private var error: String?
    @State private var confirmingDelete = false

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    private var nameProblem: String? {
        if trimmedName.isEmpty { return "Enter a name." }
        if trimmedName.count > 64 { return "Use at most 64 characters." }
        if takenNames.contains(trimmedName) { return "Another list already has this name." }
        if description.count > Config.maxDescription { return "Use at most \(Config.maxDescription) characters for the description." }
        return nil
    }

    private var entryCount: Int {
        text.split(whereSeparator: \.isNewline).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.m) {
                    if let o = original { Text("Edit \(o)").font(TypeScale.heading).foregroundStyle(Palette.ink.color) }
                    Panel {
                        FieldRow(title: "Name", text: $name)
                        Hairline()
                        FieldRow(title: "Description", text: $description, prompt: "Optional")
                        Hairline()
                        ActionRow(action: $action)
                    }
                    Text("Entries").font(TypeScale.bodyStrong).foregroundStyle(Palette.ink.color)
                    TextEditor(text: $text)
                        .font(.system(.body, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(Space.s)
                        .frame(minHeight: 150)
                        .background(Palette.surface.color, in: RoundedRectangle(cornerRadius: Radius.row))
                        .overlay(RoundedRectangle(cornerRadius: Radius.row).stroke(Palette.hairline.color, lineWidth: 1))
                    SheetNote("One per line: an address or range (203.0.113.7, 198.51.100.0/24, 2400:cb00::/32), a domain with its subdomains (example.com), one exact name (full:www.example.com) or an AS number (AS13335). Lines starting with # are notes. Only IPv4 is routed for now; the rest is kept for upcoming domain and ASN routing.")
                }
                .padding(.horizontal, Space.xl).padding(.vertical, Space.s)
            }
            .scrollIndicators(.never)
            SheetBar(error: error ?? (name.isEmpty ? nil : nameProblem), leading: original == nil ? nil : AnyView(
                Button("Delete List") { confirmingDelete = true }
                    .buttonStyle(.plain).font(TypeScale.bodyStrong).foregroundStyle(Palette.danger.color)
                    .accessibilityHint("Removes this list and its entries"))) {
                if model.busy { ProgressView().controlSize(.small) }
                SheetButton(title: "Cancel") { dismiss() }
                SheetButton(title: original == nil ? "Add" : "Save", primary: true, disabled: nameProblem != nil || model.busy) { Task { await save() } }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .confirmationDialog("Delete \(original ?? "")?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) {
                guard let o = original else { return }
                Task { await model.removeList(o); dismiss() }
            }
        } message: {
            Text("Its \(plural(entryCount, "entry", "entries")) are deleted. Export the settings first (splitroute config export) to keep a copy.")
        }
    }

    private func save() async {
        let entries = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let r = await model.saveCustom(original: original, name: trimmedName, action: action, entries: entries, description: description.trimmingCharacters(in: .whitespaces))
        original = r.name
        error = r.error
        if r.error == nil { dismiss() }
    }
}

struct ImportEditor: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let takenNames: Set<String>
    @State private var name = ""
    @State private var url = ""
    @State private var description = ""
    @State private var action: Action = .block
    @State private var error: String?

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }
    private var trimmedURL: String { url.trimmingCharacters(in: .whitespaces) }

    private var problem: String? {
        if trimmedName.isEmpty || trimmedURL.isEmpty { return "" }
        if trimmedName.count > 64 { return "Use at most 64 characters for the name." }
        if takenNames.contains(trimmedName) { return "Another list already has this name." }
        if description.count > Config.maxDescription { return "Use at most \(Config.maxDescription) characters for the description." }
        guard let u = URLComponents(string: trimmedURL), u.scheme?.lowercased() == "https", u.host?.isEmpty == false else {
            return "Enter an https URL."
        }
        if u.user != nil || u.password != nil { return "Remove the user name and password from the URL." }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.m) {
                    Panel {
                        FieldRow(title: "Name", text: $name)
                        Hairline()
                        FieldRow(title: "URL", text: $url, prompt: "https://example.com/hosts.txt")
                        Hairline()
                        FieldRow(title: "Description", text: $description, prompt: "Optional")
                        Hairline()
                        ActionRow(action: $action)
                    }
                    SheetNote("Plain lists (one entry per line), hosts files, Surge/Clash domain sets and sing-box rule-sets (.srs). The list is added at once and downloads in the background, then again every day; a failed download keeps the last good copy. Every user of this Mac can see the URL, so don't use one that contains a token or password.")
                }
                .padding(.horizontal, Space.xl).padding(.vertical, Space.s)
            }
            .scrollIndicators(.never)
            SheetBar(error: error ?? problem) {
                if model.busy { ProgressView().controlSize(.small) }
                SheetButton(title: "Cancel") { dismiss() }
                SheetButton(title: "Import", primary: true, disabled: problem != nil || model.busy) {
                    Task {
                        error = await model.importList(name: trimmedName, url: trimmedURL, action: action, description: description.trimmingCharacters(in: .whitespaces))
                        if error == nil { dismiss() }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Edits a list from a URL: its name, address and description. The name keeps the downloaded entries. A new address is
/// downloaded at once, and the old entries go (entries from another source would mislead).
struct EditImportSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let list: RouteList
    let takenNames: Set<String>
    @State private var name = ""
    @State private var url = ""
    @State private var description = ""
    @State private var error: String?

    private var trimmedURL: String { url.trimmingCharacters(in: .whitespaces) }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    private var problem: String? {
        if trimmedURL.isEmpty || trimmedName.isEmpty { return "" }
        if trimmedName.count > 64 { return "Use at most 64 characters for the name." }
        if takenNames.contains(trimmedName) { return "Another list already has this name." }
        if description.count > Config.maxDescription { return "Use at most \(Config.maxDescription) characters for the description." }
        guard let u = URLComponents(string: trimmedURL), u.scheme?.lowercased() == "https", u.host?.isEmpty == false else { return "Enter an https URL." }
        if u.user != nil || u.password != nil { return "Remove the user name and password from the URL." }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Space.m) {
                Text("Edit List").font(TypeScale.heading).foregroundStyle(Palette.ink.color)
                Panel {
                    FieldRow(title: "Name", text: $name)
                    Hairline()
                    FieldRow(title: "URL", text: $url, prompt: "https://example.com/hosts.txt")
                    Hairline()
                    FieldRow(title: "Description", text: $description, prompt: "Optional")
                }
                SheetNote("A new address replaces the list's entries when it is downloaded. Every user of this Mac can see the URL, so don't use one that contains a token or password.")
            }
            .padding(.horizontal, Space.xl).padding(.top, Space.l)
            Spacer(minLength: 0)
            SheetBar(error: error ?? problem) {
                if model.busy { ProgressView().controlSize(.small) }
                SheetButton(title: "Cancel") { dismiss() }
                SheetButton(title: "Save", primary: true, disabled: problem != nil || model.busy) {
                    Task {
                        error = await model.updateImport(name: list.name, newName: trimmedName, url: trimmedURL, description: description.trimmingCharacters(in: .whitespaces))
                        if error == nil { dismiss() }
                    }
                }
            }
        }
        .onAppear {
            name = list.name
            url = list.importSource?.url ?? ""
            description = list.description ?? ""
        }
    }
}
