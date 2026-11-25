import AppKit
import Design
import SwiftUI

import UniformTypeIdentifiers

/// How servers are given: pasted, or from a file.
private enum AddServersTab: String, CaseIterable, Identifiable {
    case paste = "Paste", file = "From File"
    var id: String { rawValue }
}

/// Adds servers from share links, a subscription address, a subscription's contents, a file of any of those, or an
/// OpenVPN profile (which has its own steps). An address is a subscription: the service downloads it, keeps the address
/// (on this Mac, readable only by the service) and groups its servers. Nothing is read from the clipboard until the
/// user asks.
struct ImportTunnelsSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    /// Closes this sheet and opens the OpenVPN profile one, with the file already chosen when there is one.
    let openProfile: (URL?) -> Void

    @State private var tab: AddServersTab = .paste
    @State private var text: String
    @State private var fileURL: URL?
    @State private var fileText: String?
    @State private var fileError: String?
    @State private var choosing = false
    @State private var choosingImage = false
    @State private var pasteDropping = false
    @State private var dropping = false
    @State private var group = ""
    @State private var working = false
    @State private var error: String?
    @State private var result: AddResult?
    @FocusState private var editing: Bool

    private static let maxFile = 4 << 20

    /// The initial text and result are for the debug snapshots; the app opens the sheet empty.
    init(openProfile: @escaping (URL?) -> Void, text: String = "", result: AddResult? = nil) {
        self.openProfile = openProfile
        self._text = State(initialValue: text)
        self._result = State(initialValue: result)
    }

    /// What will be added: what is typed, or what the file holds.
    private var payload: String { tab == .paste ? text : (fileText ?? "") }
    private var trimmed: String { payload.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// One word that starts with http:// or https://.
    private var isAddress: Bool {
        !trimmed.contains(where: \.isWhitespace) && (trimmed.hasPrefix("https://") || trimmed.hasPrefix("http://"))
    }
    private var isProfile: Bool { tab == .file && fileURL?.pathExtension.lowercased() == "ovpn" }

    private var canAdd: Bool {
        if isProfile { return true }
        return !trimmed.isEmpty && !(isAddress && trimmed.hasPrefix("http://"))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            if let result { resultView(result) } else if working { workingView } else { inputView }
        }
        .padding(Space.xl)
        .frame(width: 560)
        .font(TypeScale.body)
        .foregroundStyle(Palette.ink.color)
    }

    // MARK: Input

    private var inputView: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            header
            SheetTabs(options: AddServersTab.allCases, selection: $tab)
            Group {
                switch tab {
                case .paste: pasteTab
                case .file: fileTab
                }
            }
            .frame(minHeight: 200, alignment: .top)

            if isAddress { addressNote }
            if let error { NoteLine(.error, error) }

            HStack(spacing: Space.s) {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(OutlineButtonStyle()).keyboardShortcut(.cancelAction)
                Button(isProfile ? "Continue" : (isAddress ? "Download and add" : "Add")) { primary() }
                    .buttonStyle(SolidButtonStyle()).keyboardShortcut(.defaultAction)
                    .opacity(canAdd ? 1 : 0.45).disabled(!canAdd)
            }
        }
        .onAppear { editing = true }
        .fileImporter(isPresented: $choosingImage, allowedContentTypes: [.image]) { r in
            if case .success(let u) = r { addQR(from: { QRReader.payloads(from: u) }) }
        }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.data, .plainText, .json]) { r in
            switch r {
            case .success(let u): load(u)
            case .failure(let e): fileError = e.localizedDescription
            }
        }
    }

    private var header: some View {
        HStack(spacing: Space.m) {
            ZStack {
                AccentSurface(RoundedRectangle(cornerRadius: Radius.row + 2, style: .continuous))
                Image(systemName: "shield.lefthalf.filled").font(.system(size: 19, weight: .medium)).foregroundStyle(Color.white)
            }
            .frame(width: 42, height: 42)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Add servers").font(TypeScale.title)
                Text("Paste links or a subscription, or import a file.")
                    .font(TypeScale.secondary).foregroundStyle(Palette.inkSecondary.color)
            }
        }
    }

    // MARK: Paste

    private var pasteTab: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $text)
                    .font(.system(size: 12.5, design: .monospaced))
                    .lineSpacing(5)
                    .scrollContentBackground(.hidden)
                    .focused($editing)
                    .padding(Space.s)
                    .accessibilityLabel("Links or subscription address")
                if text.isEmpty {
                    // verbatim: Text turns an address in a string into a blue link, and a placeholder is all one color
                    Text(verbatim: "vless://…\nvmess://…\nhttps://example.com/subscription")
                        .font(.system(size: 12.5, design: .monospaced)).foregroundStyle(Palette.inkSecondary.color.opacity(0.7))
                        .lineSpacing(5)
                        .padding(.horizontal, Space.s + 5).padding(.vertical, Space.s + 8).allowsHitTesting(false)
                }
            }
            .frame(height: 138)
            .background(pasteDropping ? Accent.color.opacity(0.10) : Glass.fill, in: RoundedRectangle(cornerRadius: Radius.row))
            // A picture with a QR code, or a link, dropped on the box.
            .onDrop(of: [.fileURL, .url, .plainText], isTargeted: $pasteDropping) { providers in dropOnPaste(providers) }
            .overlay(RoundedRectangle(cornerRadius: Radius.row)
                .stroke(editing ? Accent.color.opacity(0.9) : Glass.stroke, lineWidth: editing ? 1.5 : 1))
            .animation(.easeOut(duration: 0.15), value: editing)

            HStack(spacing: Space.m) {
                Button { pasteFromClipboard() } label: {
                    Label("Paste from clipboard", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(OutlineButtonStyle())
                Button { choosingImage = true } label: {
                    Label("Scan QR image…", systemImage: "qrcode.viewfinder")
                }
                .buttonStyle(OutlineButtonStyle())
                if let seen = Self.recognized(text) {
                    Label(seen, systemImage: "checkmark.circle.fill").font(TypeScale.secondary).foregroundStyle(Palette.success.color)
                        .transition(.opacity)
                }
                Spacer()
            }
            .animation(.easeOut(duration: 0.15), value: Self.recognized(text))
            Text("Share links: vless://, vmess://, trojan://, ss://, hysteria2://, tuic://, anytls://. A subscription address starts with https://.")
                .font(TypeScale.secondary).foregroundStyle(Palette.inkSecondary.color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The clipboard's text, or the QR code in an image on it. Read only when the person presses the button.
    private func pasteFromClipboard() {
        if let s = NSPasteboard.general.string(forType: .string) { text = s; error = nil; return }
        addQR(from: { QRReader.payloads(from: .general) })
    }

    /// Adds what the QR codes in a picture say, one per line; says so when there is none.
    private func addQR(from read: @escaping () -> [String]) {
        error = nil
        Task {
            let found = await Task.detached { read() }.value
            guard !found.isEmpty else { error = "No QR code found in that picture."; return }
            text = ([text.trimmingCharacters(in: .whitespacesAndNewlines)].filter { !$0.isEmpty } + found).joined(separator: "\n")
        }
    }

    /// A dropped picture is read for QR codes; a dropped link or text is added as it is.
    private func dropOnPaste(_ providers: [NSItemProvider]) -> Bool {
        guard let p = providers.first else { return false }
        if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async { addQR(from: { QRReader.payloads(from: url) }) }
            }
            return true
        }
        _ = p.loadObject(ofClass: String.self) { s, _ in
            guard let s, !s.isEmpty else { return }
            DispatchQueue.main.async { text = ([text.trimmingCharacters(in: .whitespacesAndNewlines)].filter { !$0.isEmpty } + [s]).joined(separator: "\n") }
        }
        return true
    }

    /// What the typed text looks like, said back to the person: a quiet check that the paste worked.
    private static func recognized(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return nil }
        if !t.contains(where: \.isWhitespace), t.hasPrefix("https://") || t.hasPrefix("http://") { return "A subscription address" }
        let schemes = ["vless://", "vmess://", "trojan://", "ss://", "hysteria2://", "hy2://", "tuic://", "anytls://"]
        let links = t.split(whereSeparator: \.isNewline).filter { l in schemes.contains { l.trimmingCharacters(in: .whitespaces).hasPrefix($0) } }.count
        if links > 0 { return plural(links, "share link") }
        if t.hasPrefix("{") { return "A sing-box configuration" }
        return nil
    }

    // MARK: From file

    private var fileTab: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            VStack(spacing: Space.s) {
                if let url = fileURL {
                    Image(systemName: isProfile ? "lock.shield" : "doc.text").font(.system(size: 30, weight: .light)).foregroundStyle(Accent.color)
                    Text(url.lastPathComponent).font(TypeScale.heading).lineLimit(1).truncationMode(.middle)
                    Text(isProfile ? "An OpenVPN profile. The next step asks for its name and sign-in."
                                   : (Self.recognized(fileText ?? "") ?? "A file of servers"))
                        .font(TypeScale.secondary).foregroundStyle(Palette.inkSecondary.color)
                    Button("Choose Another…") { choosing = true }.buttonStyle(OutlineButtonStyle()).padding(.top, 4)
                } else {
                    Image(systemName: "arrow.down.doc").font(.system(size: 30, weight: .light))
                        .foregroundStyle(dropping ? Accent.color : Palette.inkSecondary.color)
                    Text("Drop a file here").font(TypeScale.heading)
                    Text("A subscription, a list of share links, a sing-box configuration (.json) or an OpenVPN profile (.ovpn)")
                        .font(TypeScale.secondary).foregroundStyle(Palette.inkSecondary.color).multilineTextAlignment(.center)
                    Button("Choose File…") { choosing = true }.buttonStyle(OutlineButtonStyle()).padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 170)
            .padding(Space.l)
            .background(dropping ? Accent.color.opacity(0.10) : Glass.fill, in: RoundedRectangle(cornerRadius: Radius.row))
            .overlay(RoundedRectangle(cornerRadius: Radius.row)
                .strokeBorder(dropping ? Accent.color : Glass.stroke, style: StrokeStyle(lineWidth: 1.5, dash: fileURL == nil ? [6, 5] : []))) 
            .animation(.easeOut(duration: 0.15), value: dropping)
            .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
                guard let p = providers.first else { return false }
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { DispatchQueue.main.async { load(url) } }
                }
                return true
            }
            if let fileError { NoteLine(.error, fileError) }
        }
    }

    private func load(_ url: URL) {
        fileError = nil
        fileText = nil
        fileURL = url
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        if url.pathExtension.lowercased() == "ovpn" { return } // read by the OpenVPN steps
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= Self.maxFile else {
            fileError = "This file is \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)); the limit is 4 MB."
            return
        }
        guard let data = try? Data(contentsOf: url), let s = String(data: data, encoding: .utf8) else {
            fileError = "This isn't a text file (UTF-8)."
            return
        }
        fileText = s
    }

    private func primary() {
        if isProfile { openProfile(fileURL); return }
        Task { await add() }
    }

    /// What an address means: it becomes a group, and the address is private.
    private var addressNote: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            if trimmed.hasPrefix("http://") {
                NoteLine(.error, "Subscriptions must use https://, because the address carries your token.")
            } else {
                Text("This is a subscription. Its servers are kept in their own group, and the address stays on this Mac where only the service can read it.")
                    .font(TypeScale.secondary).foregroundStyle(Palette.inkSecondary.color)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Space.s) {
                    Text("Group name").font(TypeScale.secondary).foregroundStyle(Palette.inkSecondary.color)
                    TextField(URL(string: trimmed)?.host ?? "Subscription", text: $group, prompt: Text(URL(string: trimmed)?.host ?? "Subscription"))
                        .labelsHidden().fieldBox().frame(maxWidth: 260)
                        .accessibilityLabel("Group name")
                }
            }
        }
    }

    private var workingView: some View {
        HStack(spacing: Space.m) {
            ProgressView().controlSize(.small)
            Text(isAddress ? "Downloading the subscription…" : "Adding servers…").font(TypeScale.body)
        }
        .frame(maxWidth: .infinity, minHeight: 120)
    }

    // MARK: Result

    @ViewBuilder private func resultView(_ r: AddResult) -> some View {
        let skipped = r.skipped ?? []
        VStack(alignment: .leading, spacing: 4) {
            Text(r.added == 0 ? "Nothing was added" : "Added \(plural(r.added, "server"))").font(TypeScale.title)
            Text(summary(r, skipped: skipped.count)).font(TypeScale.secondary)
                .foregroundStyle(Palette.inkSecondary.color).fixedSize(horizontal: false, vertical: true)
        }
        if !skipped.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.s) {
                    ForEach(skipped) { s in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(s.label).font(TypeScale.bodyStrong).lineLimit(1)
                            Text(s.reason).font(TypeScale.secondary).foregroundStyle(Palette.inkSecondary.color)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(Space.m)
            }
            .frame(maxHeight: 180)
            .background(Glass.fill, in: RoundedRectangle(cornerRadius: Radius.row))
            .overlay(RoundedRectangle(cornerRadius: Radius.row).stroke(Glass.stroke, lineWidth: 1))
        }
        HStack {
            Spacer()
            if r.added == 0 { Button("Back") { result = nil }.buttonStyle(OutlineButtonStyle()) }
            Button("Done") { dismiss() }.buttonStyle(SolidButtonStyle()).keyboardShortcut(.defaultAction)
        }
    }

    private func summary(_ r: AddResult, skipped: Int) -> String {
        var parts: [String] = []
        if let g = r.group { parts.append("They are in the group “\(g)”.") }
        if skipped > 0 {
            parts.append(r.added == 0
                ? "\(plural(skipped, "link")) couldn't be used:"
                : "\(plural(skipped, "link")) were skipped:")
        } else if r.added > 0 {
            parts.append("Connect one from the list.")
        }
        return parts.joined(separator: " ")
    }

    // MARK: Action

    private func add() async {
        error = nil
        working = true
        let name = group.trimmingCharacters(in: .whitespaces)
        let r = await model.addTunnels(text: isAddress ? nil : payload, url: isAddress ? trimmed : nil, name: name)
        working = false
        switch r {
        case .success(let res): result = res
        case .failure(let e): error = e.localizedDescription
        }
    }
}
