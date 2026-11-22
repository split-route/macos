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
            Picker("Add from", selection: $tab) {
                ForEach(AddTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(.top, 16)
            .padding(.bottom, 8)
            switch tab {
            case .ready: ReadyListsTab()
            case .url: ImportEditor(takenNames: taken)
            case .file: FileImportTab(takenNames: taken)
            case .custom: CustomListEditor(original: nil, name: "", action: .direct, text: "", takenNames: taken)
            }
        }
        // Fits under the toolbar of the 580 pt window.
        .frame(width: 560, height: 512)
    }
}

/// Release lists not added yet, by title. Adding keeps the sheet open, so
/// several can be added in a row.
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
            SearchField(text: $query, prompt: "Search lists…")
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                // Don't start in the search field (the sheet would focus it); click to search.
                .onAppear { DispatchQueue.main.async { NSApp.keyWindow?.makeFirstResponder(nil) } }
            Form {
                Section {
                    if model.available.isEmpty {
                        Text("Can't reach the latest release to see which lists it has.").foregroundStyle(.secondary)
                    } else if missing.isEmpty {
                        Text(query.isEmpty ? "Every ready-made list is added." : "No lists match.").foregroundStyle(.secondary)
                    }
                    ForEach(missing) { i in
                        let action = actions[i.name] ?? i.action
                        SettingRow(i.title, description: i.description) {
                            ActionPicker(action: action) { a, _ in actions[i.name] = a } // pick the tunnel on the Lists page
                            Button("Add") { Task { await model.enableRelease(i.name, action) } }
                                .disabled(model.busy)
                        }
                    }
                } footer: {
                    ActionsFooter()
                }
            }
            .formStyle(.grouped)
            SheetButtons(error: model.error("lists")) {
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
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
    @State private var name = ""
    @State private var action: Action = .block
    @State private var choosing = false
    @State private var error: String?
    @State private var done: EntryEdit?

    /// The service takes requests up to 8 MiB; leave room for JSON escaping.
    private static let maxBytes = 6 << 20

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    private var problem: String? {
        if text == nil || trimmedName.isEmpty { return "" }
        if trimmedName.count > 64 { return "Use at most 64 characters for the name." }
        if takenNames.contains(trimmedName) { return "Another list already has this name." }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    SettingRow(file?.lastPathComponent ?? "No file chosen",
                               description: text.map { plural($0.split(whereSeparator: \.isNewline).count, "line") }) {
                        Button("Choose File…") { choosing = true }
                    }
                    TextField("Name", text: $name)
                    Picker("Action", selection: $action) {
                        ForEach(Action.allCases) { Text($0.label).tag($0) }
                    }
                } header: {
                    Text("Import from a file").font(.headline)
                } footer: {
                    Text("Plain lists (one address, range, domain or AS number per line), hosts files and Surge/Clash domain sets, up to 6 MB. Lines that aren't entries are skipped. The entries are copied into a custom list you can edit; for a list that changes, use From URL so it stays up to date.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)
            .disabled(done != nil)
            SheetButtons(error: error ?? problem, success: done.map(summary)) {
                if done != nil {
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                        .prominent()
                } else {
                    Button("Cancel", role: .cancel) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button("Import") { Task { await importFile() } }
                        .keyboardShortcut(.defaultAction)
                        .prominent()
                        .disabled(problem != nil || model.busy)
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
        file = url
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= Self.maxBytes else {
            error = "This file is \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)); the limit is 6 MB. Put it online and use From URL instead."
            return
        }
        guard let data = try? Data(contentsOf: url), let s = String(data: data, encoding: .utf8) else {
            error = "This isn't a text file (UTF-8)."
            return
        }
        text = s
        if trimmedName.isEmpty { name = url.deletingPathExtension().lastPathComponent }
    }

    private func importFile() async {
        guard let text else { return }
        let r = await model.createFromFile(name: trimmedName, action: action, text: text)
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
    @State var text: String
    let takenNames: Set<String>
    @State private var error: String?

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    private var nameProblem: String? {
        if trimmedName.isEmpty { return "Enter a name." }
        if trimmedName.count > 64 { return "Use at most 64 characters." }
        if takenNames.contains(trimmedName) { return "Another list already has this name." }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $name)
                    Picker("Action", selection: $action) {
                        ForEach(Action.allCases) { Text($0.label).tag($0) }
                    }
                } header: {
                    Text(original == nil ? "New Custom List" : "Edit \(original!)").font(.headline)
                }
                Section {
                    TextEditor(text: $text)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 160)
                } header: {
                    Text("Entries")
                } footer: {
                    Text("One per line: an address or range (203.0.113.7, 198.51.100.0/24, 2400:cb00::/32), a domain with its subdomains (example.com), one exact name (full:www.example.com) or an AS number (AS13335). Lines starting with # are notes. Only IPv4 is routed for now; the rest is kept for upcoming domain and ASN routing.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)
            VStack(alignment: .leading, spacing: 8) {
                if let e = error ?? (name.isEmpty ? nil : nameProblem) { ErrorText(e) }
                HStack {
                    Spacer()
                    if model.busy { ProgressView().controlSize(.small) }
                    Button("Cancel", role: .cancel) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button(original == nil ? "Add" : "Save") { Task { await save() } }
                        .keyboardShortcut(.defaultAction)
                        .prominent()
                        .disabled(nameProblem != nil || model.busy)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func save() async {
        let entries = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let r = await model.saveCustom(original: original, name: trimmedName, action: action, entries: entries)
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
    @State private var action: Action = .block
    @State private var error: String?

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }
    private var trimmedURL: String { url.trimmingCharacters(in: .whitespaces) }

    private var problem: String? {
        if trimmedName.isEmpty || trimmedURL.isEmpty { return "" }
        if trimmedName.count > 64 { return "Use at most 64 characters for the name." }
        if takenNames.contains(trimmedName) { return "Another list already has this name." }
        guard let u = URLComponents(string: trimmedURL), u.scheme?.lowercased() == "https", u.host?.isEmpty == false else {
            return "Enter an https URL."
        }
        if u.user != nil || u.password != nil { return "Remove the user name and password from the URL." }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $name)
                    TextField("URL", text: $url, prompt: Text("https://example.com/hosts.txt"))
                    Picker("Action", selection: $action) {
                        ForEach(Action.allCases) { Text($0.label).tag($0) }
                    }
                } header: {
                    Text("Import from URL").font(.headline)
                } footer: {
                    Text("Plain lists (one entry per line), hosts files and Surge/Clash domain sets. The service downloads it now and every day; a failed download keeps the last good copy. Every user of this Mac can see the URL, so don't use one that contains a token or password.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)
            VStack(alignment: .leading, spacing: 8) {
                if let e = error ?? problem, !e.isEmpty { ErrorText(e) }
                HStack {
                    Spacer()
                    if model.busy { ProgressView().controlSize(.small) }
                    Button("Cancel", role: .cancel) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button("Import") {
                        Task {
                            error = await model.importList(name: trimmedName, url: trimmedURL, action: action)
                            if error == nil { dismiss() }
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .prominent()
                    .disabled(problem != nil || model.busy)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
