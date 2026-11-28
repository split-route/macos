import Design
import SwiftUI
import UniformTypeIdentifiers

/// The four ways to add a list, opened from the Lists page's + button.
enum AddTab: String, CaseIterable, Identifiable {
    case ready = "Ready-made", url = "From URL", file = "From File", custom = "Custom"
    var id: String { rawValue }
}

/// Adding a list: a page with a tab for each way (ready-made, from a URL, from a file, a custom rule).
struct AddListPage: View {
    @EnvironmentObject private var model: AppModel
    @State var tab: AddTab

    private var taken: Set<String> { Set((model.config?.lists ?? []).map(\.name)) }

    var body: some View {
        let tabs = AnyView(SheetTabs(options: AddTab.allCases, selection: $tab).frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, Space.s))
        switch tab {
        case .ready: ReadyListsTab(tabs: tabs)
        case .url: ImportEditor(takenNames: taken, tabs: tabs)
        case .file: FileImportTab(takenNames: taken, tabs: tabs)
        case .custom: CustomListEditor(original: nil, name: "", action: .direct, description: "", rules: RuleSpec(), ruleSet: false, takenNames: taken, tabs: tabs)
        }
    }
}

/// Release lists not added yet, by title. Adding keeps the sheet open, so
/// several can be added in a row; each shows on the page at once, downloading.
struct ReadyListsTab: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.closePage) private var close
    @State private var query = ""
    @State private var actions: [String: Action] = [:] // changed before adding

    private var missing: [ListInfo] {
        let added = Set((model.config?.lists ?? []).map(\.name))
        let q = query.trimmingCharacters(in: .whitespaces)
        return model.available.filter { !added.contains($0) }
            .map { model.info($0) ?? ListInfo(name: $0, title: $0, description: "", action: .direct) }
            .filter { q.isEmpty || "\($0.title) \($0.description) \($0.name)".localizedCaseInsensitiveContains(q) }
    }

    var tabs: AnyView?

    var body: some View {
        SubPage(tabs: tabs) {
            SheetSearch(text: $query, prompt: "Search rules…")
                // Don't start in the search field (the sheet would focus it); click to search.
                .onAppear { DispatchQueue.main.async { NSApp.keyWindow?.makeFirstResponder(nil) } }
            VStack(alignment: .leading, spacing: Space.m) {
                if model.available.isEmpty {
                    SheetNote("Can't reach the server to see which ready-made rules it has.")
                } else if missing.isEmpty {
                    SheetNote(query.isEmpty ? "Every ready-made rule is added." : "No rules match.")
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
                    .environment(\.searchQuery, query) // the rows mark what was searched for
                }
                SheetNote("No Action keeps a rule without applying it. Direct skips every server. Block drops the traffic. Active Server sends it through the server you're connected with. Changes apply right away.")
            }
        } footer: {
            SheetBar(error: model.error("lists")) {
                SheetButton(title: "Done", primary: true) { close() }
            }
        }
    }
}

/// Creates a custom list from a file on this Mac. The app reads the file and
/// sends its text; the service parses it like an import.
struct FileImportTab: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.closePage) private var close
    let takenNames: Set<String>
    @State private var file: URL?
    @State private var text: String?
    @State private var binary: Data? // a sing-box rule-set (.srs, or its JSON source)
    @State private var name = ""
    @State private var action: Action = .block
    @State private var description = ""
    @State private var choosing = false
    @State private var error: String?
    @State private var done: String? // what was added

    private static let maxText = 5 << 20 // a plain list
    private static let maxRuleSet = Daemon.maxRuleSet

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    private var problem: String? {
        if (text == nil && binary == nil) || trimmedName.isEmpty { return "" }
        if trimmedName.count > 64 { return "Use at most 64 characters for the name." }
        if takenNames.contains(trimmedName) { return "Another rule already has this name." }
        if description.count > Config.maxDescription { return "Use at most \(Config.maxDescription) characters for the description." }
        return nil
    }

    var tabs: AnyView?

    var body: some View {
        SubPage(tabs: tabs) {
            VStack(alignment: .leading, spacing: Space.m) {
                Panel {
                    FormRow(file?.lastPathComponent ?? "No file chosen",
                            detail: binary != nil ? "sing-box rule-set, kept as it is" : text.map { plural($0.split(whereSeparator: \.isNewline).count, "line") }) {
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
                SheetNote("A sing-box rule-set (.srs, or its JSON source) is used exactly as it is: everything sing-box can run in one works, up to 16 MB. A plain text file (one domain, address or range per line, hosts files, Surge/Clash domain sets, up to 5 MB) becomes the fields of a rule you can edit; lines that aren't entries are skipped. For one that changes, use From URL so it stays up to date.")
            }
        } footer: {
            SheetBar(error: error ?? problem, success: done) {
                if done != nil {
                    SheetButton(title: "Done", primary: true) { close() }
                } else {
                    SheetButton(title: "Cancel") { close() }
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
        guard size <= Self.maxRuleSet else {
            error = "This file is \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)); the limit is 16 MB. Put it online and use From URL instead."
            return
        }
        guard let data = try? Data(contentsOf: url) else {
            error = "This file can't be read."
            return
        }
        if Daemon.looksLikeRuleSet(data) {
            binary = data
        } else if data.count <= Self.maxText, let s = String(data: data, encoding: .utf8) {
            text = s
        } else if data.count > Self.maxText {
            error = "A plain text file can be up to 5 MB. Put it online and use From URL instead."
            return
        } else {
            error = "This isn't a text file (UTF-8) or a sing-box rule-set (.srs)."
            return
        }
        if trimmedName.isEmpty { name = url.deletingPathExtension().lastPathComponent }
    }

    private func importFile() async {
        guard text != nil || binary != nil else { return }
        let r = await model.createFromFile(name: trimmedName, action: action, text: text ?? "", ruleSet: binary, description: description.trimmingCharacters(in: .whitespaces))
        error = r.error
        if r.error == nil { done = r.summary ?? "Added \(trimmedName)." }
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

struct CustomTarget: Identifiable, Equatable {
    let id = UUID()
    let list: RouteList? // nil: a new list
}

/// Creates or edits a custom list: a rule built from fields. The fields have sing-box's names and mean what they mean
/// there; "or" and "and" say how they combine, and "invert" negates the rule. Saving asks the service to check every
/// value first, so a mistake is reported here, next to the field, and not when the list is applied.
struct CustomListEditor: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.closePage) private var close
    @State var original: String?
    @State var name: String
    @State var action: Action
    @State var description: String
    let rules: RuleSpec
    /// The list is a sing-box rule-set kept as it was imported: its rules are not edited here.
    let ruleSet: Bool
    let takenNames: Set<String>
    @State private var error: String?
    @State private var confirmingDelete = false
    @State private var loaded = false
    @State private var mode = "or"
    @State private var invert = false
    /// What is typed in each field, one value per line, by the field's sing-box name.
    @State private var texts: [String: String] = [:]
    @State private var apps: [String] = []
    @State private var network: Set<String> = []

    /// The fields of the rule, grouped, with sing-box's names and a line on what each matches.
    private typealias FieldInfo = (key: String, title: String, hint: String, example: String)
    private static let groups: [(title: String, fields: [FieldInfo])] = [
        ("Domain", [
            ("domain", "Domain", "Exactly this name.", "www.example.com"),
            ("domain_suffix", "Domain Suffix", "This name and everything under it.", "example.com"),
            ("domain_keyword", "Domain Keyword", "Names that contain the word.", "google"),
            ("domain_regex", "Domain Regex", "Names that match the pattern.", "^ads[0-9]+\\.example\\.com$"),
        ]),
        ("Address", [("ip_cidr", "IP CIDR", "An address or a range.", "203.0.113.7\n203.0.113.0/24\n2400:cb00::/32")]),
        ("Port", [
            ("port", "Port", "A destination port.", "443"),
            ("port_range", "Port Range", "A range of destination ports. Either end may be left out.", "8000:9000\n:1023"),
        ]),
    ]
    private static let programFields: [FieldInfo] = [
        ("process_name", "Process Name", "The program's name.", "curl"),
        ("process_path", "Process Path", "The program's full path.", "/usr/bin/curl"),
        ("process_path_regex", "Process Path Regex", "A pattern for the path.", "^/opt/tools/"),
    ]
    private static let networks = ["tcp", "udp", "icmp"]

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    private var nameProblem: String? {
        if trimmedName.isEmpty { return "Enter a name." }
        if trimmedName.count > 64 { return "Use at most 64 characters." }
        if takenNames.contains(trimmedName) { return "Another rule already has this name." }
        if description.count > Config.maxDescription { return "Use at most \(Config.maxDescription) characters for the description." }
        return nil
    }

    var tabs: AnyView?

    var body: some View {
        SubPage(tabs: tabs) {
            VStack(alignment: .leading, spacing: Space.m) {
                Panel {
                    FieldRow(title: "Name", text: $name)
                    Hairline()
                    FieldRow(title: "Description", text: $description, prompt: "Optional")
                    Hairline()
                    ActionRow(action: $action)
                }
                if ruleSet {
                    SheetNote("This rule is a sing-box rule-set, kept exactly as it was imported: sing-box runs every entry in it. To change its entries, import a new file or address. The name, description and action can be changed above.")
                } else {
                    builder
                }
            }
        } footer: {
            SheetBar(error: error ?? (name.isEmpty ? nil : nameProblem), leading: original == nil ? nil : AnyView(
                Button("Delete Rule") { confirmingDelete = true }
                    .buttonStyle(.plain).font(TypeScale.bodyStrong).foregroundStyle(Palette.danger.color)
                    .accessibilityHint("Removes this rule and its fields"))) {
                if model.busy { ProgressView().controlSize(.small) }
                SheetButton(title: "Cancel") { close() }
                SheetButton(title: original == nil ? "Add" : "Save", primary: true, disabled: nameProblem != nil || model.busy) { Task { await save() } }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear(perform: load)
        .confirmationDialog("Delete \(original ?? "")?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) {
                guard let o = original else { return }
                Task { await model.removeList(o); close() }
            }
        } message: {
            Text("Its rules are deleted.")
        }
    }

    // MARK: The rule

    private var builder: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            Panel {
                FormRow("Logic", detail: mode == "or" ? "A connection matches when it matches any field below."
                                                       : "A connection matches only when it matches every field below.") {
                    SelectMenu(title: mode.uppercased(), options: ["or", "and"], label: { $0.uppercased() }, selected: mode) { mode = $0 }
                }
                Hairline()
                FormRow("Invert", detail: "Match everything except what this rule describes.") {
                    Toggle("Invert", isOn: $invert).labelsHidden().toggleStyle(.switch).tint(Accent.color)
                }
            }
            ForEach(Self.groups, id: \.title) { g in
                section(g.fields)
            }
            VStack(alignment: .leading, spacing: Space.l) {
                applicationsPanel
                ForEach(Self.programFields, id: \.key) { field($0.key, $0.title, $0.hint, $0.example) }
                SheetNote("The engine looks up which program each connection comes from, which costs a little per connection. It only does so while a rule names programs.")
            }
            VStack(alignment: .leading, spacing: Space.l) {
                Panel {
                    FormRow("Network", detail: "The transport: tcp, udp or icmp") {
                        HStack(spacing: Space.m) {
                            ForEach(Self.networks, id: \.self) { n in
                                Toggle(n, isOn: Binding(get: { network.contains(n) }, set: { on in
                                    if on { network.insert(n) } else { network.remove(n) }
                                })).toggleStyle(.checkbox).font(TypeScale.body)
                            }
                        }
                    }
                }
            }
            SheetNote("One value per line. The service checks every value when you save.")
        }
    }

    /// A group's fields, with no heading of its own: each field names itself.
    private func section(_ fields: [FieldInfo]) -> some View {
        VStack(alignment: .leading, spacing: Space.l) {
            ForEach(fields, id: \.key) { field($0.key, $0.title, $0.hint, $0.example) }
        }
    }

    /// One field: its title (sing-box's name, written out), a box for its values and what it matches.
    private func field(_ key: String, _ title: String, _ hint: String, _ example: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(TypeScale.bodyStrong).foregroundStyle(Palette.ink.color)
                Text(hint).font(TypeScale.secondary).foregroundStyle(Palette.inkSecondary.color)
            }
            // The box grows with its text up to 10 lines, then the text scrolls inside it. A TextEditor has no height of its
            // own, so an invisible copy of the text (same font, same wrapping, at most 10 lines) sets it.
            Text(verbatim: (texts[key] ?? "") + "\n") // the last empty line counts, so a new line makes room at once
                .font(.system(size: 12.5, design: .monospaced))
                .lineLimit(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Space.s + 5).padding(.vertical, Space.s + 1)
                .frame(minHeight: 72, alignment: .topLeading)
                .opacity(0)
                .accessibilityHidden(true)
                .overlay {
                    ZStack(alignment: .topLeading) {
                        TextEditor(text: Binding(get: { texts[key] ?? "" }, set: { texts[key] = $0 }))
                            .font(.system(size: 12.5, design: .monospaced))
                            .scrollContentBackground(.hidden)
                            .padding(Space.s)
                            .accessibilityLabel(key)
                        if (texts[key] ?? "").isEmpty {
                            // The example, inside the box until something is typed. verbatim: no blue links, no markdown.
                            Text(verbatim: example)
                                .font(.system(size: 12.5, design: .monospaced))
                                .foregroundStyle(Palette.inkSecondary.color.opacity(0.7))
                                .padding(.horizontal, Space.s + 5).padding(.vertical, Space.s + 1)
                                .allowsHitTesting(false).accessibilityHidden(true)
                        }
                    }
                }
                .background(Glass.fill, in: RoundedRectangle(cornerRadius: Radius.row))
                .overlay(RoundedRectangle(cornerRadius: Radius.row).stroke(Glass.stroke, lineWidth: 1))
        }
    }

    /// The applications of this rule, picked from Finder. Each shows its icon and name.
    private var applicationsPanel: some View {
        Panel {
            FormRow("Applications", detail: "Everything these programs send, whatever the address.") {
                Button("Add…") { chooseApps() }.buttonStyle(OutlineButtonStyle())
            }
            ForEach(apps, id: \.self) { path in
                Hairline()
                AppRow(path: path) { apps.removeAll { $0 == path } }
            }
        }
    }

    private func chooseApps() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Add"
        panel.begin { r in
            guard r == .OK else { return }
            for u in panel.urls where !apps.contains(u.path) { apps.append(u.path) }
        }
    }

    // MARK: Fields and the rule

    private func load() {
        guard !loaded else { return }
        loaded = true
        mode = rules.mode
        invert = rules.invert
        apps = rules.applications
        network = Set(rules.network)
        texts = [
            "domain": rules.domain.joined(separator: "\n"), "domain_suffix": rules.domainSuffix.joined(separator: "\n"),
            "domain_keyword": rules.domainKeyword.joined(separator: "\n"), "domain_regex": rules.domainRegex.joined(separator: "\n"),
            "ip_cidr": rules.ipCIDR.joined(separator: "\n"), "port": rules.port.map(String.init).joined(separator: "\n"),
            "port_range": rules.portRange.joined(separator: "\n"), "process_name": rules.processName.joined(separator: "\n"),
            "process_path": rules.processPath.joined(separator: "\n"), "process_path_regex": rules.processPathRegex.joined(separator: "\n"),
        ]
    }

    private func lines(_ key: String) -> [String] {
        (texts[key] ?? "").split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// The rule as typed, or what is wrong with it.
    private func spec() throws -> RuleSpec {
        var s = RuleSpec()
        s.mode = mode
        s.invert = invert
        s.domain = lines("domain"); s.domainSuffix = lines("domain_suffix"); s.domainKeyword = lines("domain_keyword")
        s.domainRegex = lines("domain_regex"); s.ipCIDR = lines("ip_cidr"); s.portRange = lines("port_range")
        s.processName = lines("process_name"); s.processPath = lines("process_path"); s.processPathRegex = lines("process_path_regex")
        s.applications = apps
        s.network = Self.networks.filter { network.contains($0) }
        for p in lines("port") {
            guard let n = Int(p), (1...65535).contains(n) else { throw StoreError("port: \"\(p)\" is not a port from 1 to 65535.") }
            s.port.append(n)
        }
        return s
    }

    private func save() async {
        let rule: RuleSpec
        if ruleSet {
            rule = rules
        } else {
            do { rule = try spec() } catch { self.error = error.localizedDescription; return }
        }
        let r = await model.saveCustom(original: original, name: trimmedName, action: action, rules: rule, description: description.trimmingCharacters(in: .whitespaces))
        original = r.name
        error = r.error
        if r.error == nil { close() }
    }
}

struct ImportEditor: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.closePage) private var close
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
        if takenNames.contains(trimmedName) { return "Another rule already has this name." }
        if description.count > Config.maxDescription { return "Use at most \(Config.maxDescription) characters for the description." }
        guard let u = URLComponents(string: trimmedURL), u.scheme?.lowercased() == "https", u.host?.isEmpty == false else {
            return "Enter an https URL."
        }
        if u.user != nil || u.password != nil { return "Remove the user name and password from the URL." }
        return nil
    }

    var tabs: AnyView?

    var body: some View {
        SubPage(tabs: tabs) {
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
                SheetNote("Plain text (one entry per line), hosts files, Surge/Clash domain sets and sing-box rule-sets (.srs). The rule is added at once and downloads in the background, then again every day; a failed download keeps the last good copy. Every user of this Mac can see the URL, so don't use one that contains a token or password.")
            }
        } footer: {
            SheetBar(error: error ?? problem) {
                if model.busy { ProgressView().controlSize(.small) }
                SheetButton(title: "Cancel") { close() }
                SheetButton(title: "Import", primary: true, disabled: problem != nil || model.busy) {
                    Task {
                        error = await model.importList(name: trimmedName, url: trimmedURL, action: action, description: description.trimmingCharacters(in: .whitespaces))
                        if error == nil { close() }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Edits a list from a URL: its name, address and description. The name keeps the downloaded entries. A new address is
/// downloaded at once, and the old entries go (entries from another source would mislead).
struct EditImportView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.closePage) private var close
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
        if takenNames.contains(trimmedName) { return "Another rule already has this name." }
        if description.count > Config.maxDescription { return "Use at most \(Config.maxDescription) characters for the description." }
        guard let u = URLComponents(string: trimmedURL), u.scheme?.lowercased() == "https", u.host?.isEmpty == false else { return "Enter an https URL." }
        if u.user != nil || u.password != nil { return "Remove the user name and password from the URL." }
        return nil
    }

    var body: some View {
        SubPage {
            VStack(alignment: .leading, spacing: Space.m) {
                Panel {
                    FieldRow(title: "Name", text: $name)
                    Hairline()
                    FieldRow(title: "URL", text: $url, prompt: "https://example.com/hosts.txt")
                    Hairline()
                    FieldRow(title: "Description", text: $description, prompt: "Optional")
                }
                SheetNote("A new address replaces the rule's entries when it is downloaded. Every user of this Mac can see the URL, so don't use one that contains a token or password.")
            }
        } footer: {
            SheetBar(error: error ?? problem) {
                if model.busy { ProgressView().controlSize(.small) }
                SheetButton(title: "Cancel") { close() }
                SheetButton(title: "Save", primary: true, disabled: problem != nil || model.busy) {
                    Task {
                        error = await model.updateImport(name: list.name, newName: trimmedName, url: trimmedURL, description: description.trimmingCharacters(in: .whitespaces))
                        if error == nil { close() }
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
