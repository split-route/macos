import Design
import SwiftUI

/// Tunnels: one switch turns the VPN on or off, and the tunnel with the mark is the one
/// that carries all traffic no list names. Choosing another switches at once. Tunnels
/// that came from a subscription are grouped under it; the rest are listed first.
struct TunnelsPage: View {
    @EnvironmentObject private var model: AppModel
    @State private var importing = false
    @State private var adding = false
    @State private var promptFor: Tunnel?
    @State private var renaming: Tunnel?
    @State private var logsFor: Tunnel?
    @State private var confirmRemove: Tunnel?
    @State private var confirmRemoveGroup: Subscription?
    /// Groups the user opened in full; a long group shows only its active tunnels until then.
    @State private var expanded: Set<String> = []

    /// A group longer than this shows only the tunnels that are on until it is opened.
    private static let collapseAbove = 8

    private var unavailable: Bool { model.connError != nil || model.tunnelList?.unavailable != nil }
    private var selectedName: String? { model.tunnelList?.selected }

    private var summary: String {
        if model.connError != nil { return "The service isn't running." }
        if model.tunnels.isEmpty { return "No tunnels yet." }
        return "Choose the tunnel that carries your traffic."
    }

    /// The default group first, then one per subscription in the order they were added.
    private struct Group: Identifiable {
        var name: String?
        var subscription: Subscription?
        var tunnels: [Tunnel]
        var id: String { name ?? "" }
    }

    private var groups: [Group] {
        var out: [Group] = []
        let def = model.tunnels.filter { $0.group == nil }
        if !def.isEmpty { out.append(Group(name: nil, tunnels: def)) }
        for sub in model.tunnelList?.subscriptions ?? [] {
            out.append(Group(name: sub.name, subscription: sub, tunnels: model.tunnels.filter { $0.group == sub.name }))
        }
        return out
    }

    var body: some View {
        PageScaffold("Tunnels", summary: summary) {
            if !model.tunnels.isEmpty, model.connError == nil {
                Button("Add tunnels") { importing = true }.buttonStyle(SolidButtonStyle()).disabled(unavailable)
            }
        } content: {
            if model.connError != nil {
                ServiceUnavailable()
            } else if model.tunnels.isEmpty && (model.tunnelList?.subscriptions ?? []).isEmpty {
                VStack(alignment: .leading, spacing: Space.m) {
                    if let u = model.tunnelList?.unavailable { NoteLine(.warning, u) }
                    if let e = model.error("tunnels") { NoteLine(.error, e) }
                    Panel {
                        EmptyState(title: "Add your first tunnel",
                                   message: "Paste a share link or a subscription address, or import an OpenVPN profile. Then turn the VPN on.",
                                   action: "Add tunnels") { importing = true }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: Space.l) {
                    if let u = model.tunnelList?.unavailable { NoteLine(.warning, u) }
                    vpnCard
                    ForEach(groups) { group in groupView(group, titled: group.name != nil) }
                }
            }
        }
        .sheet(isPresented: $importing) {
            ImportTunnelsSheet(openProfile: {
                importing = false
                DispatchQueue.main.async { adding = true }
            }).environmentObject(model)
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
            Text("The tunnel and its saved credentials are deleted. Keep the profile or link if you want to add it again.")
        }
        .confirmationDialog("Remove \(confirmRemoveGroup?.name ?? "")?", isPresented: Binding(
            get: { confirmRemoveGroup != nil }, set: { if !$0 { confirmRemoveGroup = nil } }
        ), presenting: confirmRemoveGroup) { g in
            Button("Remove group", role: .destructive) { Task { await model.removeGroup(g.name) } }
        } message: { g in
            Text("Its \(plural(g.tunnels, "tunnel")) and the saved subscription address are deleted. A list that uses one of them must be moved to another tunnel first.")
        }
    }

    // MARK: The switch

    /// The one switch. Off, traffic uses the normal connection. On, everything no list names goes
    /// through the tunnel with the mark.
    private var vpnCard: some View {
        Panel {
            VStack(alignment: .leading, spacing: Space.s) {
                HStack(spacing: Space.l) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("VPN").font(TypeScale.heading).foregroundStyle(Palette.ink.color)
                        Text(model.summary).font(TypeScale.secondary).foregroundStyle(Palette.inkSecondary.color)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: Space.m)
                    Toggle("VPN", isOn: Binding(get: { model.vpnOn }, set: { on in Task { await model.setVPN(on) } }))
                        .labelsHidden().toggleStyle(.switch).tint(Palette.ink.color)
                        .disabled(model.tunnels.isEmpty)
                        .accessibilityLabel("VPN")
                }
                if let e = model.error("vpn") { NoteLine(.error, e) }
            }
            .padding(Space.l)
        }
    }

    // MARK: Groups and rows

    @ViewBuilder private func groupView(_ group: Group, titled: Bool) -> some View {
        let all = group.tunnels
        let long = all.count > Self.collapseAbove
        let open = expanded.contains(group.id)
        // A long group shows the selected tunnel and any that is in use, not hundreds of idle ones.
        let shown = long && !open ? all.filter { $0.state != .disconnected || $0.name == selectedName } : all
        VStack(alignment: .leading, spacing: Space.s) {
            if titled {
                HStack(alignment: .firstTextBaseline, spacing: Space.m) {
                    SectionTitle(group.name ?? "")
                    Text(group.subscription.map { subscriptionLine($0) } ?? plural(all.count, "tunnel"))
                        .font(TypeScale.secondary).foregroundStyle(Palette.inkSecondary.color)
                    Spacer()
                    if let sub = group.subscription {
                        Button("Remove group") { confirmRemoveGroup = sub }
                            .buttonStyle(OutlineButtonStyle())
                            .accessibilityLabel("Remove group \(sub.name)")
                    }
                }
            }
            if let name = group.name, let e = model.error("group:\(name)") { NoteLine(.error, e) }
            if let e = group.subscription?.error, !e.isEmpty { NoteLine(.warning, "Last update failed: \(e)") }
            Panel {
                if all.isEmpty {
                    Text("This group has no tunnels.").font(TypeScale.body).foregroundStyle(Palette.inkSecondary.color)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(Space.l)
                }
                LazyVStack(spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { i, t in
                        if i > 0 { Hairline() }
                        row(t)
                    }
                }
                if long {
                    if !shown.isEmpty { Hairline() }
                    Button {
                        if open { expanded.remove(group.id) } else { expanded.insert(group.id) }
                    } label: {
                        Text(open ? "Show only the selected tunnel and those in use" : "Show all \(all.count) tunnels")
                            .font(TypeScale.bodyStrong).foregroundStyle(Palette.ink.color)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(Space.l).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func subscriptionLine(_ sub: Subscription) -> String {
        var s = plural(sub.tunnels, "tunnel")
        if let d = parseGoTime(sub.updatedAt) { s += ", updated \(relative(d))" }
        return s
    }

    private func select(_ t: Tunnel) {
        Task { if await model.selectTunnel(t) { promptFor = t } }
    }

    @ViewBuilder private func row(_ t: Tunnel) -> some View {
        let selected = t.name == selectedName
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(spacing: Space.m) {
                Button { select(t) } label: {
                    HStack(spacing: Space.m) {
                        // A tick for the tunnel that carries the traffic; an empty ring for the rest.
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 18))
                            .foregroundStyle(selected ? Palette.ink.color : Palette.hairline.color)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t.name).font(TypeScale.bodyStrong).foregroundStyle(Palette.ink.color).lineLimit(1).help(t.name)
                            Text(detail(t)).font(TypeScale.secondary).foregroundStyle(Palette.inkSecondary.color)
                                .monospacedDigit().lineLimit(2)
                        }
                        .layoutPriority(-1)
                        Spacer(minLength: Space.m)
                        if let l = label(t, selected: selected) {
                            Text(l).font(TypeScale.secondary).foregroundStyle(Palette.inkSecondary.color)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(t.name)
                .accessibilityValue(label(t, selected: selected) ?? "")
                .accessibilityHint("Use this tunnel for all traffic that no list names")
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
                Menu {
                    Button("Credentials…") { promptFor = t }
                        .disabled(!t.needsAuth && !t.keyEncrypted)
                    Button("Show Log…") { logsFor = t }
                    Button("Rename…") { renaming = t }
                    Divider()
                    Button("Remove…", role: .destructive) { confirmRemove = t }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold))
                        .frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("More for \(t.name)")
            }
            if t.state == .failed, let e = t.error { NoteLine(.error, e) }
            if t.state == .reconnecting, let e = t.error { NoteLine(.warning, e) }
            if let w = t.warning, !w.isEmpty { NoteLine(.warning, w) }
            if let e = model.error("tunnel:\(t.name)") { NoteLine(.error, e) }
        }
        .padding(.vertical, Space.m).padding(.horizontal, Space.l)
    }

    /// The state, shown only where it means something: on the selected tunnel while the VPN is on,
    /// and on an OpenVPN tunnel a list uses that is up or trying.
    private func label(_ t: Tunnel, selected: Bool) -> String? {
        switch t.state {
        case .disconnected: return nil
        case .connecting: return "Connecting"
        case .reconnecting: return "Reconnecting"
        case .needsAuth: return "Needs sign-in"
        case .connected: return "Connected"
        case .ready: return selected ? "Ready" : nil
        case .failed: return "Failed"
        }
    }

    /// The protocol and the server, then what the state adds.
    private func detail(_ t: Tunnel) -> String {
        let base = [t.protocolLabel, t.remotes?.first].compactMap { $0 }.joined(separator: ", ")
        switch t.state {
        case .needsAuth: return t.need == "key" ? "Needs the private key password" : "Needs a username and password"
        case .connected:
            var p: [String] = []
            if let ip = t.localIP, !ip.isEmpty { p.append(ip) }
            if let since = parseGoTime(t.since) { p.append("since \(relative(since))") }
            if let i = t.bytesIn, let o = t.bytesOut, i + o > 0 {
                p.append("\(ByteCountFormatter.string(fromByteCount: Int64(i), countStyle: .binary)) down, \(ByteCountFormatter.string(fromByteCount: Int64(o), countStyle: .binary)) up")
            }
            return p.isEmpty ? base : p.joined(separator: ", ")
        default: return base
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
