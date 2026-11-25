import Design
import SwiftUI
import UniformTypeIdentifiers

/// Imports an OpenVPN profile: choose the file, see what it asks for (a
/// profile that runs commands must be confirmed), name it, optionally save credentials.
struct AddTunnelSheet: View {
    /// A profile already chosen (in the Add servers dialog): loaded as soon as this opens.
    var initialFile: URL?
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var choosing = false
    @State private var dropping = false
    @State private var file: URL?
    @State private var text: String?
    @State private var check: TunnelCheck?
    @State private var name = ""
    @State private var secrets = TunnelSecrets()
    @State private var error: String?
    @State private var working = false

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }
    private var takenNames: Set<String> { Set(model.tunnels.map { $0.name.lowercased() }) }

    private var problem: String? {
        guard check != nil else { return "" }
        if trimmedName.isEmpty { return "" }
        if trimmedName.count > 64 { return "Use at most 64 characters for the name." }
        if takenNames.contains(trimmedName.lowercased()) { return "Another server has this name." }
        if let s = check?.scripts, !s.isEmpty { return "This profile runs \(s.joined(separator: ", ")), which Splitroute does not support." }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            header
            fileCard
            if check != nil {
                Panel {
                    FormRow("Name") { TextField("Name", text: $name).labelsHidden().fieldBox().frame(maxWidth: 280) }
                    if check?.needsAuth == true {
                        Hairline()
                        FormRow("Username") { TextField("Username", text: $secrets.username, prompt: Text("Optional")).labelsHidden().fieldBox().frame(maxWidth: 280) }
                        Hairline()
                        FormRow("Password") { SecureField("Password", text: $secrets.password, prompt: Text("Optional")).labelsHidden().fieldBox().frame(maxWidth: 280) }
                    }
                    if check?.keyEncrypted == true {
                        Hairline()
                        FormRow("Key password", detail: "Opens the profile's private key.") {
                            SecureField("Private key password", text: $secrets.keyPassword, prompt: Text("Optional")).labelsHidden().fieldBox().frame(maxWidth: 280)
                        }
                    }
                }
                if check?.needsAuth == true || check?.keyEncrypted == true {
                    Label("What you enter here is saved in the Keychain.", systemImage: "lock.fill")
                        .font(TypeScale.secondary).foregroundStyle(Palette.inkSecondary.color)
                }
            }
            if let s = check?.scripts, !s.isEmpty {
                NoteLine(.warning, "This profile runs commands when it connects (\(s.joined(separator: ", "))). Splitroute never runs scripts, so it can't import it.")
            }
            if let e = error ?? problem, !e.isEmpty { NoteLine(.error, e) }
            HStack(spacing: Space.s) {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(OutlineButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Import") { Task { await run() } }
                    .buttonStyle(SolidButtonStyle()).keyboardShortcut(.defaultAction)
                    .opacity(problem == nil && !working ? 1 : 0.45).disabled(problem != nil || working)
            }
        }
        .padding(Space.xl)
        .frame(width: 540)
        .font(TypeScale.body)
        .foregroundStyle(Palette.ink.color)
        .task { if let u = initialFile, file == nil { await load(u) } }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.data, .plainText]) { result in
            switch result {
            case .success(let url): Task { await load(url) }
            case .failure(let e): error = e.localizedDescription
            }
        }
    }

    private var header: some View {
        HStack(spacing: Space.m) {
            ZStack {
                AccentSurface(RoundedRectangle(cornerRadius: Radius.row + 2, style: .continuous))
                Image(systemName: "lock.shield").font(.system(size: 19, weight: .medium)).foregroundStyle(Color.white)
            }
            .frame(width: 42, height: 42)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Import an OpenVPN profile").font(TypeScale.title)
                Text("A .ovpn file. Certificates and keys it points to are read from its folder.")
                    .font(TypeScale.secondary).foregroundStyle(Palette.inkSecondary.color)
            }
        }
    }

    /// The chosen file and what it asks for, or a place to drop one.
    private var fileCard: some View {
        VStack(spacing: Space.s) {
            if let url = file {
                HStack(spacing: Space.m) {
                    Image(systemName: "doc.text").font(.system(size: 24, weight: .light)).foregroundStyle(Accent.color).frame(width: 34)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(url.lastPathComponent).font(TypeScale.heading).lineLimit(1).truncationMode(.middle)
                        if let server = check?.remotes?.first {
                            Text("Server: \(server)").font(TypeScale.secondary).foregroundStyle(Palette.inkSecondary.color)
                        }
                        HStack(spacing: 6) {
                            if check?.needsAuth == true { chip("Needs sign-in", "person.fill") }
                            if check?.keyEncrypted == true { chip("Encrypted key", "key.fill") }
                        }
                    }
                    Spacer(minLength: Space.s)
                    Button("Choose Another…") { choosing = true }.buttonStyle(OutlineButtonStyle())
                }
            } else {
                Image(systemName: "arrow.down.doc").font(.system(size: 28, weight: .light))
                    .foregroundStyle(dropping ? Accent.color : Palette.inkSecondary.color)
                Text("Drop a .ovpn file here").font(TypeScale.heading)
                Button("Choose File…") { choosing = true }.buttonStyle(OutlineButtonStyle()).padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, minHeight: file == nil ? 130 : 0)
        .padding(Space.l)
        .background(dropping ? Accent.color.opacity(0.10) : Glass.fill, in: RoundedRectangle(cornerRadius: Radius.row))
        .overlay(RoundedRectangle(cornerRadius: Radius.row)
            .strokeBorder(dropping ? Accent.color : Glass.stroke, style: StrokeStyle(lineWidth: 1.5, dash: file == nil ? [6, 5] : [])))
        .animation(.easeOut(duration: 0.15), value: dropping)
        .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
            guard let p = providers.first else { return false }
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url { Task { await load(url) } }
            }
            return true
        }
    }

    private func chip(_ text: String, _ symbol: String) -> some View {
        Label(text, systemImage: symbol).font(.system(size: 10.5, weight: .medium))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .glassCapsule()
            .foregroundStyle(Palette.inkSecondary.color)
    }

    private func load(_ url: URL) async {
        error = nil
        check = nil
        text = nil
        file = url
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url), data.count <= 1 << 20, let s = String(data: data, encoding: .utf8) else {
            error = "This isn't a profile (a UTF-8 text file up to 1 MB)."
            return
        }
        do {
            let r = try OvpnProfile.inline(s, directory: url.deletingLastPathComponent())
            if let c = r.credentials { secrets.username = c.username; secrets.password = c.password }
            switch await model.checkTunnel(text: r.text) {
            case .success(let c):
                text = r.text
                check = c
                if trimmedName.isEmpty { name = url.deletingPathExtension().lastPathComponent }
            case .failure(let e):
                error = e.localizedDescription
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func run() async {
        guard let text else { return }
        working = true
        defer { working = false }
        error = await model.importTunnel(name: trimmedName, text: text, secrets: secrets)
        if error == nil { dismiss() }
    }
}
