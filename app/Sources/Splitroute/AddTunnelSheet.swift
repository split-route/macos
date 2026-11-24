import SwiftUI

/// Imports an OpenVPN profile: choose the file, see what it asks for (a
/// profile that runs commands must be confirmed), name it, optionally save credentials.
struct AddTunnelSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var choosing = false
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
        VStack(spacing: 0) {
            Form {
                Section {
                    SettingRow(file?.lastPathComponent ?? "No file chosen",
                               description: check?.remotes?.first.map { "Server: \($0)" }) {
                        Button("Choose File…") { choosing = true }
                    }
                    if check != nil {
                        TextField("Name", text: $name)
                        if check?.needsAuth == true {
                            TextField("Username", text: $secrets.username, prompt: Text("Optional"))
                            SecureField("Password", text: $secrets.password, prompt: Text("Optional"))
                        }
                        if check?.keyEncrypted == true {
                            SecureField("Private key password", text: $secrets.keyPassword, prompt: Text("Optional"))
                        }
                    }
                } header: {
                    Text("Import an OpenVPN profile").font(.headline)
                } footer: {
                    Text("A .ovpn file; certificates and keys it points to are read from the same folder. Credentials you enter are saved in the Keychain.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let s = check?.scripts, !s.isEmpty {
                    Section {
                        WarningText("This profile runs commands when it connects (\(s.joined(separator: ", "))). Splitroute never runs scripts, so it can't import it.")
                    }
                }
            }
            .formStyle(.grouped)
            SheetButtons(error: error ?? problem) {
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Import") { Task { await run() } }
                    .keyboardShortcut(.defaultAction)
                    .prominent()
                    .disabled(problem != nil || working)
            }
        }
        .frame(width: 500)
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.data, .plainText]) { result in
            switch result {
            case .success(let url): Task { await load(url) }
            case .failure(let e): error = e.localizedDescription
            }
        }
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
