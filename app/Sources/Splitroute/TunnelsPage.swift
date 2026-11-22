import SwiftUI

/// OpenVPN tunnels: import a profile, connect and disconnect, see the state.
/// Credentials are asked once and kept in the Keychain; the service only gets
/// them to connect. Routing lists work next to a tunnel as they do next to any VPN.
struct TunnelsPage: View {
    @EnvironmentObject private var model: AppModel
    @State private var adding = false
    @State private var promptFor: Tunnel?
    @State private var renaming: Tunnel?
    @State private var logsFor: Tunnel?
    @State private var confirmRemove: Tunnel?

    var body: some View {
        Group {
            if model.connError != nil {
                Form { ServiceUnavailable() }
            } else if model.tunnels.isEmpty {
                GeometryReader { g in
                    ScrollView {
                        VStack(spacing: 12) {
                            Image(systemName: "lock.shield")
                                .font(.system(size: 40, weight: .light))
                                .foregroundStyle(.secondary)
                            Text("No tunnels yet").font(.title3.weight(.semibold))
                            Text("Import an OpenVPN profile (.ovpn) to connect from here. Your lists keep working next to it.")
                                .multilineTextAlignment(.center)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: 360)
                            if let u = model.tunnelList?.unavailable { WarningText(u) }
                            if let e = model.error("tunnels") { ErrorText(e) }
                            Button("Import Profile…") { adding = true }
                                .prominent()
                                .disabled(model.tunnelList?.unavailable != nil)
                        }
                        .frame(maxWidth: .infinity, minHeight: g.size.height)
                    }
                }
            } else {
                Form {
                    if let u = model.tunnelList?.unavailable { Section { WarningText(u) } }
                    Section { ForEach(model.tunnels) { row($0) } }
                }
                .formStyle(.grouped)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { adding = true } label: { Image(systemName: "plus") }
                    .help("Import Profile")
                    .accessibilityLabel("Import Profile")
                    .disabled(model.connError != nil || model.tunnelList?.unavailable != nil)
            }
        }
        .sheet(isPresented: $adding) { AddTunnelSheet().environmentObject(model) }
        .sheet(item: $promptFor) { t in CredentialsSheet(tunnel: t).environmentObject(model) }
        .sheet(item: $renaming) { t in RenameTunnelSheet(tunnel: t).environmentObject(model) }
        .sheet(item: $logsFor) { t in TunnelLogSheet(tunnel: t).environmentObject(model) }
        .confirmationDialog("Remove \(confirmRemove?.name ?? "")?", isPresented: Binding(
            get: { confirmRemove != nil }, set: { if !$0 { confirmRemove = nil } }
        ), presenting: confirmRemove) { t in
            Button("Remove", role: .destructive) { Task { await model.removeTunnel(t.name) } }
        } message: { _ in
            Text("The profile and its saved credentials are deleted. Keep the .ovpn file if you want to import it again.")
        }
    }

    @ViewBuilder private func row(_ t: Tunnel) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: t.state == .connected ? "lock.shield.fill" : "lock.shield")
                .foregroundStyle(t.state == .connected ? .green : .secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(t.name)
                Text(detail(t)).font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if t.state == .failed, let e = t.error { ErrorText(e) }
                if t.state == .reconnecting, let e = t.error { WarningText(e) }
                if let e = model.error("tunnel:\(t.name)") { ErrorText(e) }
            }
            Spacer(minLength: 12)
            if t.state == .needsAuth {
                Button("Enter Credentials…") { promptFor = t }
            }
            Toggle("Connected", isOn: Binding(get: { t.isActive }, set: { on in toggle(t, on) }))
                .labelsHidden()
                .toggleStyle(.switch)
            Menu {
                Button("Credentials…") { promptFor = t }
                    .disabled(!t.needsAuth && !t.keyEncrypted)
                Toggle("Connect when the service starts", isOn: Binding(
                    get: { t.autoConnect }, set: { on in Task { await model.setTunnelAutoConnect(t.name, on) } }))
                Button("Show Log…") { logsFor = t }
                Button("Rename…") { renaming = t }
                Divider()
                Button("Remove…", role: .destructive) { confirmRemove = t }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.vertical, 4)
    }

    private func toggle(_ t: Tunnel, _ on: Bool) {
        if !on { Task { await model.disconnectTunnel(t.name) }; return }
        if model.needsCredentialPrompt(t) { promptFor = t; return }
        // The server refused what is saved: ask again instead of retrying the same password.
        if t.state == .failed, let e = t.error, e.contains("username or password") || e.contains("key password") {
            promptFor = t
            return
        }
        Task { await model.connectTunnel(t) }
    }

    private func detail(_ t: Tunnel) -> String {
        switch t.state {
        case .disconnected: return (t.remotes?.first).map { "Disconnected · \($0)" } ?? "Disconnected"
        case .connecting: return "Connecting…"
        case .needsAuth: return t.need == "key" ? "Needs the private key password" : "Needs a username and password"
        case .connected:
            var p = ["Connected"]
            if let ip = t.localIP, !ip.isEmpty { p.append(ip) }
            if let since = parseGoTime(t.since) { p.append("since \(relative(since))") }
            if let i = t.bytesIn, let o = t.bytesOut, i + o > 0 {
                p.append("↓ \(ByteCountFormatter.string(fromByteCount: Int64(i), countStyle: .binary)) ↑ \(ByteCountFormatter.string(fromByteCount: Int64(o), countStyle: .binary))")
            }
            return p.joined(separator: " · ")
        case .reconnecting: return "Reconnecting…"
        case .failed: return "Stopped"
        }
    }
}

/// Asks for a tunnel's username, password and private key password, and optionally
/// keeps them in the Keychain. Connects when confirmed (or just saves, if already running).
struct CredentialsSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let tunnel: Tunnel
    @State private var secrets = TunnelSecrets()
    @State private var remember = true

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    if tunnel.needsAuth {
                        TextField("Username", text: $secrets.username)
                        SecureField("Password", text: $secrets.password)
                    }
                    if tunnel.keyEncrypted || tunnel.need == "key" {
                        SecureField("Private key password", text: $secrets.keyPassword)
                    }
                    Toggle("Save in the Keychain", isOn: $remember)
                } header: {
                    Text("Credentials for \(tunnel.name)").font(.headline)
                } footer: {
                    Text("Sent to the service to connect and kept in its memory only while the tunnel is on.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            SheetButtons {
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(tunnel.isActive ? "Save" : "Connect") {
                    let s = secrets
                    let r = remember
                    Task {
                        if tunnel.isActive {
                            if r { TunnelKeychain.save(tunnel.name, s) }
                            try? await Daemon.tunnelCredentials(tunnel.name, secrets: s)
                        } else {
                            await model.connectTunnel(tunnel, secrets: s, remember: r)
                        }
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .prominent()
                .disabled(secrets.isEmpty)
            }
        }
        .frame(width: 440)
        .onAppear { secrets = TunnelKeychain.load(tunnel.name) ?? TunnelSecrets() }
    }
}

struct RenameTunnelSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let tunnel: Tunnel
    @State private var name = ""
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("Name", text: $name).onSubmit { Task { await save() } }
            }
            .formStyle(.grouped)
            SheetButtons(error: error) {
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Rename") { Task { await save() } }
                    .keyboardShortcut(.defaultAction)
                    .prominent()
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || name == tunnel.name)
            }
        }
        .frame(width: 400)
        .onAppear { name = tunnel.name }
    }

    private func save() async {
        error = await model.renameTunnel(tunnel.name, to: name.trimmingCharacters(in: .whitespaces))
        if error == nil { dismiss() }
    }
}

struct TunnelLogSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let tunnel: Tunnel
    @State private var lines: [String] = []

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                Text(lines.isEmpty ? "No log yet." : lines.joined(separator: "\n"))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .background(Color(nsColor: .textBackgroundColor))
            SheetButtons {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
                }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction).prominent()
            }
        }
        .frame(width: 640, height: 420)
        .task {
            while !Task.isCancelled {
                lines = await model.tunnelLogs(tunnel.name)
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }
}
