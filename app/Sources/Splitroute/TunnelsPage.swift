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
    @State private var editingGroup: Subscription?

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
        .sheet(item: $editingGroup) { g in SubscriptionEditSheet(subscription: g).environmentObject(model) }
        .confirmationDialog("Remove \(confirmRemove?.name ?? "")?", isPresented: Binding(
            get: { confirmRemove != nil }, set: { if !$0 { confirmRemove = nil } }
        ), presenting: confirmRemove) { t in
            Button("Remove", role: .destructive) { Task { await model.removeTunnel(t.name) } }
        } message: { _ in
            Text("The tunnel and its saved credentials are deleted. Keep the profile or link if you want to add it again.")
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
        // Subscriptions are open until the user folds them; the default group has no header to fold.
        let open = !titled || !model.isCollapsed(group.id)
        VStack(alignment: .leading, spacing: Space.s) {
            if titled { groupHeader(group, open: open) }
            if let name = group.name {
                if let e = model.error("group:\(name)") { NoteLine(.error, e) }
                if let r = model.groupResults[name] {
                    Text(r).font(TypeScale.secondary).foregroundStyle(Palette.inkSecondary.color)
                }
            }
            if let e = group.subscription?.error, !e.isEmpty { NoteLine(.warning, "Last update failed: \(e)") }
            if open {
                Panel {
                    if all.isEmpty {
                        Text("This group has no tunnels.").font(TypeScale.body).foregroundStyle(Palette.inkSecondary.color)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(Space.l)
                    }
                    LazyVStack(spacing: 0) {
                        ForEach(Array(all.enumerated()), id: \.element.id) { i, t in
                            if i > 0 { Hairline() }
                            row(t)
                        }
                    }
                }
            }
        }
    }

    /// The group's name and what the provider reported, a button to fold it, and the update and info buttons.
    @ViewBuilder private func groupHeader(_ group: Group, open: Bool) -> some View {
        let name = group.name ?? ""
        let updating = model.updatingGroups.contains(name)
        HStack(alignment: .center, spacing: Space.m) {
            Button { withAnimation(.easeInOut(duration: 0.15)) { model.toggleCollapsed(name) } } label: {
                HStack(alignment: .center, spacing: Space.s) {
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                        .rotationEffect(.degrees(open ? 90 : 0)).frame(width: 14)
                        .foregroundStyle(Palette.inkSecondary.color)
                    VStack(alignment: .leading, spacing: 2) {
                        SectionTitle(name).lineLimit(1).padding(.top, 0)
                        if let line = headerLine(group) {
                            Text(line).font(TypeScale.secondary).foregroundStyle(Palette.inkSecondary.color)
                                .monospacedDigit().lineLimit(2)
                        }
                    }
                    Spacer(minLength: Space.m)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(name)
            .accessibilityValue(open ? "Expanded" : "Collapsed")
            .accessibilityHint("Shows or hides the tunnels of this subscription")
            if let sub = group.subscription {
                Button { Task { await model.updateGroup(sub.name) } } label: {
                    ZStack {
                        if updating { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
                    }
                    .font(.system(size: 14, weight: .regular)).frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain).disabled(updating || unavailable)
                .help("Update this subscription")
                .accessibilityLabel("Update \(sub.name)")
                Button { editingGroup = sub } label: {
                    Image(systemName: "info.circle").font(.system(size: 14, weight: .regular))
                        .frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Edit or remove this subscription")
                .accessibilityLabel("Edit \(sub.name)")
            }
        }
    }

    /// What the provider reported (used, total, expiry), or the count and the last update.
    private func headerLine(_ group: Group) -> String? {
        guard let sub = group.subscription else { return plural(group.tunnels.count, "tunnel") }
        var parts: [String] = []
        if let u = sub.usage {
            parts.append("↑ \(Self.bytes(u.upload))")
            parts.append("↓ \(Self.bytes(u.download))")
            if let t = u.total, t > 0 { parts.append("Total \(Self.bytes(t))") }
            if let e = u.expire, e > 0 { parts.append("Expires \(Self.day(Date(timeIntervalSince1970: TimeInterval(e))))") }
        }
        let base = subscriptionLine(sub)
        return parts.isEmpty ? base : parts.joined(separator: " · ") + "\n" + base
    }

    private static func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .decimal) }

    private static func day(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
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

/// Edits a subscription: its name and address, and removing it with its tunnels.
struct SubscriptionEditSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let subscription: Subscription
    @State private var name = ""
    @State private var url = ""
    @State private var savedURL: String?  // nil while it is being read
    @State private var error: String?
    @State private var working = false
    @State private var confirmRemove = false

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }
    private var trimmedURL: String { url.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var changed: Bool {
        guard let savedURL else { return false }
        return trimmedName != subscription.name || trimmedURL != savedURL
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("Name", text: $name)
                TextField("Address", text: $url, prompt: Text(savedURL == nil ? "Reading…" : "https://"), axis: .vertical)
                    .lineLimit(1...4).disabled(savedURL == nil)
                    .accessibilityLabel("Subscription address")
                if trimmedURL.hasPrefix("http://") {
                    NoteLine(.error, "Subscriptions must use https://, because the address carries your token.")
                }
                Text("The address stays on this Mac. Saving it does not download anything: use the update button.")
                    .font(TypeScale.secondary).foregroundStyle(Palette.inkSecondary.color)
                Section {
                    Button("Remove subscription…", role: .destructive) { confirmRemove = true }
                        .disabled(working)
                }
            }
            .formStyle(.grouped)
            SheetButtons(error: error) {
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { Task { await save() } }
                    .keyboardShortcut(.defaultAction).prominent()
                    .disabled(!changed || trimmedName.isEmpty || trimmedURL.isEmpty || working)
            }
        }
        .frame(width: 480)
        .task {
            name = subscription.name
            switch await model.groupURL(subscription.name) {
            case .success(let u): url = u; savedURL = u
            case .failure(let e): error = e.localizedDescription
            }
        }
        .confirmationDialog("Remove \(subscription.name)?", isPresented: $confirmRemove) {
            Button("Remove subscription", role: .destructive) { Task { await remove() } }
        } message: {
            Text("Its \(plural(subscription.tunnels, "tunnel")) and the saved address are deleted. A list that uses one of them must be moved to another tunnel first.")
        }
    }

    private func save() async {
        working = true
        defer { working = false }
        error = await model.editGroup(subscription.name,
                                      newName: trimmedName != subscription.name ? trimmedName : nil,
                                      url: trimmedURL != savedURL ? trimmedURL : nil)
        if error == nil { dismiss() }
    }

    private func remove() async {
        working = true
        defer { working = false }
        error = await model.removeGroup(subscription.name)
        if error == nil { dismiss() }
    }
}
