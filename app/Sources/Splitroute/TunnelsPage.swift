import Design
import SwiftUI

/// Tunnels: one switch turns the VPN on or off, and the tunnel with the mark is the one
/// that carries all traffic no list names. Choosing another switches at once. Tunnels
/// that came from a subscription are grouped under it; the rest are listed first.
struct TunnelsPage: View {
    @EnvironmentObject private var model: AppModel
    @State private var importing = false
    private var query: Binding<String> { Binding(get: { model.searches["servers"] ?? "" }, set: { model.searches["servers"] = $0 }) }
    /// An OpenVPN profile chosen in the Add servers dialog, handed to the profile dialog.
    @State private var profileFile: ProfileChoice?
    @State private var promptFor: Tunnel?
    @State private var renaming: Tunnel?
    @State private var noting: Tunnel?
    @State private var logsFor: Tunnel?
    @State private var confirmRemove: Tunnel?
    @State private var editingGroup: Subscription?
    @AppStorage(Prefs.sortByPing) private var sortByPing = true

    private var unavailable: Bool { model.connError != nil || model.tunnelList?.unavailable != nil }
    private var selectedName: String? { model.tunnelList?.selected }

    /// Subscriptions that just finished updating: true if it worked. Cleared after a few seconds.
    @State private var updated: [String: Bool] = [:]

    /// The default group first, then one per subscription in the order they were added.
    private struct Group: Identifiable {
        var name: String?
        var subscription: Subscription?
        var tunnels: [Tunnel]
        var id: String { name ?? "" }
    }

    @State private var latency: LatencyFilter = .all

    private var searching: Bool { !query.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty || latency != .all }

    /// Matches by name, protocol, transport or group, and by the latency filter once a test has run.
    private func matches(_ t: Tunnel) -> Bool {
        guard latency.allows(model.testResults[t.name]) else { return false }
        let q = query.wrappedValue.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        return ([t.name, t.protocolName, t.transport ?? "", t.group ?? ""] + (t.remotes ?? [])).contains { $0.localizedCaseInsensitiveContains(q) }
    }

    private var groups: [Group] {
        var out: [Group] = []
        let def = ordered(model.tunnels.filter { $0.group == nil && matches($0) })
        if !def.isEmpty { out.append(Group(name: nil, tunnels: def)) }
        for sub in model.tunnelList?.subscriptions ?? [] {
            let ts = ordered(model.tunnels.filter { $0.group == sub.name && matches($0) })
            // While searching, a group with no match is hidden; otherwise an empty subscription still shows.
            if searching && ts.isEmpty { continue }
            out.append(Group(name: sub.name, subscription: sub, tunnels: ts))
        }
        return out
    }

    /// After a connectivity test: the fastest first, the ones that didn't answer last, the rest of the order kept. Only
    /// the display changes; the stored order doesn't. The order goes back when the next test starts or the VPN stops.
    private func ordered(_ ts: [Tunnel]) -> [Tunnel] {
        var out = ts
        if sortByPing, !model.testing, !model.testResults.isEmpty {
            func rank(_ t: Tunnel) -> Int {
                if case .ms(let ms)? = model.testResults[t.name] { return ms }
                return Int.max
            }
            out = ts.enumerated().sorted { a, b in
                let (x, y) = (rank(a.element), rank(b.element))
                return x != y ? x < y : a.offset < b.offset
            }.map(\.element)
        }
        // Favorites first, each part keeping its order.
        return out.filter(\.pinned) + out.filter { !$0.pinned }
    }

    var body: some View {
        PageScaffold("Servers") {
            // The controls fade in and out with the page's state instead of popping.
            let showBar = !model.tunnels.isEmpty && model.connError == nil
            ZStack {
                if showBar {
                    ToolbarGroup {
                        latencyMenu
                        ToolbarSearch(text: query, prompt: "Search servers…")
                        ToolbarAddButton("Add servers") { importing = true }.disabled(unavailable)
                    }
                    .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.2), value: showBar)
        } content: {
            if model.connError != nil {
                ServiceUnavailable()
            } else if model.tunnels.isEmpty && (model.tunnelList?.subscriptions ?? []).isEmpty {
                VStack(alignment: .leading, spacing: Space.m) {
                    if let u = model.tunnelList?.unavailable { NoteLine(.warning, u) }
                    if let e = model.error("tunnels") { NoteLine(.error, e) }
                    Panel {
                        EmptyState(symbol: "shield", title: "Add your first server",
                                   message: "Paste a share link or a subscription address, or import an OpenVPN profile. Then connect.",
                                   action: "Add servers") { importing = true }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: Space.l) {
                    if let u = model.tunnelList?.unavailable { NoteLine(.warning, u) }
                    vpnCard
                    if searching && groups.isEmpty {
                        Text("No servers match.").font(TypeScale.body).foregroundStyle(Palette.inkSecondary.color)
                            .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, Space.xl)
                    }
                    ForEach(groups) { group in groupView(group, titled: group.name != nil) }
                }
            }
        }
        .sheet(isPresented: $importing) {
            ImportTunnelsSheet(openProfile: { file in
                importing = false
                DispatchQueue.main.async { profileFile = ProfileChoice(url: file) }
            }).environmentObject(model).glassSheet()
        }
        .sheet(item: $profileFile) { choice in AddTunnelSheet(initialFile: choice.url).environmentObject(model).glassSheet() }
        .sheet(item: $promptFor) { t in EditServerSheet(tunnel: t).environmentObject(model).glassSheet() }
        .sheet(item: $renaming) { t in RenameTunnelSheet(tunnel: t).environmentObject(model).glassSheet() }
        .sheet(item: $noting) { t in ServerNoteSheet(tunnel: t).environmentObject(model).glassSheet() }
        .sheet(item: $logsFor) { t in TunnelLogSheet(tunnel: t).environmentObject(model).glassSheet() }
        .sheet(item: $editingGroup) { g in SubscriptionEditSheet(subscription: g).environmentObject(model).glassSheet() }
        .confirmationDialog("Remove \(confirmRemove?.name ?? "")?", isPresented: Binding(
            get: { confirmRemove != nil }, set: { if !$0 { confirmRemove = nil } }
        ), presenting: confirmRemove) { t in
            Button("Remove", role: .destructive) { Task { await model.removeTunnel(t.name) } }
        } message: { _ in
            Text("The server and its saved credentials are deleted. Keep the profile or link if you want to add it again.")
        }
    }

    // MARK: The switch

    /// The one switch. Off, traffic uses the normal connection. On, everything no list names goes
    /// through the tunnel with the mark.
    private var vpnCard: some View {
        Panel {
            VStack(alignment: .leading, spacing: Space.s) {
                HStack(spacing: Space.l) {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 40, weight: .regular))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(Color.white, Accent.gradient) // this symbol: the check is the first layer, the shield body the second
                        .shadow(color: Accent.glow, radius: 6)
                        .overlay(alignment: .top) {
                            // A gloss on the upper half, like a lit glass shield.
                            Image(systemName: "shield").font(.system(size: 40))
                                .foregroundStyle(LinearGradient(colors: [Color.white.opacity(0.45), Color.white.opacity(0.05)], startPoint: .top, endPoint: .bottom))
                                .allowsHitTesting(false)
                        }
                        .frame(width: 52)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.vpnOn ? "Connected" : "Disconnected").font(TypeScale.heading).foregroundStyle(Palette.ink.color)
                        Text(vpnSubtitle).font(TypeScale.secondary).foregroundStyle(Palette.inkSecondary.color)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: Space.m)
                    PendingToggle("Connection", isOn: Binding(get: { model.vpnOn }, set: { on in Task { await model.setVPN(on) } }),
                                  pending: model.pending.contains("vpn"))
                        .disabled(model.tunnels.isEmpty)
                }
                if let e = model.error("vpn") { NoteLine(.error, e) }
            }
            .padding(Space.l)
            Hairline()
            connectivityRow
        }
    }

    /// What the connection is doing; with it off, the tunnel that will carry the traffic once it is on.
    private var vpnSubtitle: String {
        if !model.vpnOn { return model.selectedTunnel?.name ?? "Select a server, then connect." }
        return model.summary
    }

    /// Like Shadowrocket's "Connectivity Test": one button, then a time or "Timeout" on each tunnel's row.
    private var connectivityRow: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Button { Task { await model.testConnectivity() } } label: {
                HStack(spacing: Space.m) {
                    Image(systemName: "gauge.with.dots.needle.67percent").font(.system(size: 14)).frame(width: 18)
                    Text("Connectivity Test").font(TypeScale.body).foregroundStyle(Palette.ink.color)
                    Spacer(minLength: Space.m)
                    if model.testing { ProgressView().controlSize(.small) } else {
                        Image(systemName: "play.circle").font(.system(size: 16))
                    }
                }
                .foregroundStyle(Palette.inkSecondary.color)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(model.testing || unavailable || model.tunnels.isEmpty)
            .accessibilityLabel("Connectivity Test")
            .accessibilityHint("Connects if needed, then measures a request through each running server.")
            if let e = model.error("test") { NoteLine(.warning, e) }
        }
        .padding(.vertical, Space.m).padding(.horizontal, Space.l)
    }

    // MARK: Groups and rows

    @ViewBuilder private func groupView(_ group: Group, titled: Bool) -> some View {
        let all = group.tunnels
        // Subscriptions are open until the user folds them; the default group has no header to fold.
        let open = !titled || !model.isCollapsed(group.id)
        VStack(alignment: .leading, spacing: Space.s) {
            Panel {
                // The title row is the first row of the group, on a tinted ground.
                if titled {
                    groupHeader(group, open: open)
                        .padding(.vertical, Space.m).padding(.horizontal, Space.l)
                        .background(Glass.header)
                }
                if open {
                    if all.isEmpty {
                        Text("This group has no servers.").font(TypeScale.body).foregroundStyle(Palette.inkSecondary.color)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(Space.l)
                    }
                    LazyVStack(spacing: 0) {
                        ForEach(Array(all.enumerated()), id: \.element.id) { i, t in
                            if i > 0 || titled { Hairline() }
                            row(t)
                        }
                    }
                }
            }
        }
    }

    /// The group's name and what the provider reported, a button to fold it, the tunnel count, and the update and info buttons.
    @ViewBuilder private func groupHeader(_ group: Group, open: Bool) -> some View {
        let name = group.name ?? ""
        let updating = model.updatingGroups.contains(name)
        HStack(alignment: .center, spacing: Space.m) {
            Button { withAnimation(.easeInOut(duration: 0.15)) { model.toggleCollapsed(name) } } label: {
                HStack(alignment: .center, spacing: Space.s) {
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                        .rotationEffect(.degrees(open ? 90 : 0)).frame(width: 14)
                        .foregroundStyle(Palette.inkSecondary.color)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(name).font(TypeScale.heading).foregroundStyle(Palette.ink.color).lineLimit(1)
                            .accessibilityAddTraits(.isHeader)
                        if let u = group.subscription?.usage { usageLine(u) }
                    }
                    Spacer(minLength: Space.m)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(name)
            .accessibilityValue(open ? "Expanded" : "Collapsed")
            .accessibilityHint("Shows or hides the servers of this subscription")
            if let sub = group.subscription {
                Text("\(group.tunnels.count)").font(TypeScale.secondary).monospacedDigit()
                    .foregroundStyle(Palette.inkSecondary.color)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .glassCapsule()
                    .accessibilityLabel(plural(group.tunnels.count, "server"))
                Button { update(sub.name) } label: {
                    ZStack {
                        if updating {
                            ProgressView().controlSize(.small)
                        } else if let ok = updated[sub.name] {
                            // The outcome for a moment, then the refresh icon again; a failure's reason is the button's tooltip.
                            Image(systemName: ok ? "checkmark" : "exclamationmark.triangle")
                                .foregroundStyle(ok ? Palette.ink.color : Palette.danger.color)
                                .transition(.opacity)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .font(.system(size: 14, weight: .regular)).roundGlass(30)
                }
                .buttonStyle(.plain).disabled(updating || unavailable)
                .help(model.error("group:\(sub.name)") ?? sub.error?.nilIfEmpty.map { "Last update failed: \($0)" } ?? "Update this subscription")
                .accessibilityLabel("Update \(sub.name)")
                Button { editingGroup = sub } label: {
                    Image(systemName: "info.circle").font(.system(size: 14, weight: .regular)).roundGlass(30)
                }
                .buttonStyle(.plain)
                .help("Edit or remove this subscription")
                .accessibilityLabel("Edit \(sub.name)")
            }
        }
    }

    /// What the provider reported, as icons: up, down, the plan's size and its end. Within 10 days the end is yellow with
    /// the days left; past it is red with (Expired).
    @ViewBuilder private func usageLine(_ u: SubscriptionUsage) -> some View {
        let expires = (u.expire ?? 0) > 0 ? Date(timeIntervalSince1970: TimeInterval(u.expire ?? 0)) : nil
        HStack(spacing: Space.m) {
            usageItem("arrow.up", Self.bytes(u.upload), "Uploaded")
            usageItem("arrow.down", Self.bytes(u.download), "Downloaded")
            if let t = u.total, t > 0 {
                switch Self.quota(used: u.upload + u.download, total: t) {
                case .out: usageItem("chart.pie", "\(Self.bytes(t)) (Used up)", "Plan used up", tone: Palette.danger.color)
                case .low(let left): usageItem("chart.pie", "\(Self.bytes(t)) (\(left)% left)", "\(left) percent of the plan left", tone: left <= 5 ? Palette.danger.color : Palette.warning.color)
                case .fine: usageItem("chart.pie", Self.bytes(t), "Plan size")
                }
            }
            if let e = expires {
                let days = Self.daysLeft(e)
                if days < 0 {
                    usageItem("calendar", "\(Self.day(e)) (Expired)", "Expired", tone: Palette.danger.color)
                } else if days < 10 {
                    usageItem("calendar", "\(Self.day(e)) (\(days == 1 ? "1 day" : "\(days) days"))", "Expires in \(days) days", tone: Palette.warning.color)
                } else {
                    usageItem("calendar", Self.day(e), "Expires")
                }
            }
        }
        .font(TypeScale.secondary).monospacedDigit().lineLimit(1)
    }

    enum Quota: Equatable { case fine, low(Int), out }

    /// How much of the plan is left: out at 0, orange under 15 percent, red under 5 (like the expiry date's colors).
    static func quota(used: Int64, total: Int64) -> Quota {
        guard total > 0 else { return .fine }
        let left = total - used
        if left <= 0 { return .out }
        let pct = Int((Double(left) / Double(total) * 100).rounded(.up))
        return pct < 15 ? .low(pct) : .fine
    }

    /// Whole days from now to the end of the plan's last day; negative once it has passed.
    static func daysLeft(_ end: Date, now: Date = Date()) -> Int {
        let cal = Calendar.current
        return cal.dateComponents([.day], from: cal.startOfDay(for: now), to: cal.startOfDay(for: end)).day ?? 0
    }

    private func usageItem(_ icon: String, _ text: String, _ label: String, tone: Color? = nil) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 10, weight: .semibold))
            Text(text)
        }
        .foregroundStyle(tone ?? Palette.inkSecondary.color)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label) \(text)")
    }

    private static func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .decimal) }

    private static func day(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    /// Updates a subscription and shows how it went on the button for a few seconds.
    private func update(_ name: String) {
        Task {
            await model.updateGroup(name)
            let ok = model.error("group:\(name)") == nil
            withAnimation { updated[name] = ok }
            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                                 userInfo: [.announcement: ok ? "Updated \(name)" : "Update of \(name) failed", .priority: NSAccessibilityPriorityLevel.high.rawValue])
            try? await Task.sleep(nanoseconds: ok ? 2_000_000_000 : 4_000_000_000)
            withAnimation { updated[name] = nil }
        }
    }

    /// Show only servers that answered a test within a time. Servers with no result yet are hidden while a filter is on.
    private var latencyMenu: some View {
        Menu {
            Picker("Latency", selection: $latency) {
                ForEach(LatencyFilter.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
            if latency != .all && model.testResults.isEmpty { Text("Run a connectivity test first.") }
        } label: {
            Image(systemName: "timer").font(.system(size: 15, weight: .medium))
                .foregroundStyle(latency == .all ? Palette.ink.color : Accent.color)
                .frame(width: 38, height: 38).glassSurface(Circle())
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("Filter by latency").accessibilityLabel("Filter by latency")
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
                        ZStack {
                            if selected {
                                AccentSurface(Circle())
                                Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Color.white)
                            } else {
                                Circle().strokeBorder(Palette.inkSecondary.color.opacity(0.6), lineWidth: 1.5)
                            }
                        }
                        .frame(width: 22, height: 22)
                        .frame(width: 26)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 5) {
                                if t.pinned { Image(systemName: "pin.fill").font(.system(size: 10)).foregroundStyle(Accent.color).accessibilityLabel("Pinned") }
                                Text((Flags.prefix(for: [t.name, t.group]).map { $0 + " " } ?? "") + t.name).font(TypeScale.bodyStrong).foregroundStyle(Palette.ink.color).lineLimit(1).help(t.name)
                            }
                            Text(detail(t)).font(TypeScale.secondary).foregroundStyle(Palette.inkSecondary.color)
                                .monospacedDigit().lineLimit(2)
                            if !t.note.isEmpty {
                                Text(t.note).font(TypeScale.secondary).italic().foregroundStyle(Palette.inkSecondary.color).lineLimit(2).help(t.note)
                            }
                        }
                        .layoutPriority(-1)
                        Spacer(minLength: Space.m)
                        if let r = model.testResults[t.name] {
                            switch r {
                            case .ms(let ms): LatencyPill(ms: ms)
                            case .failed(let why, _): FailurePill(why).help(r.explanation)
                            }
                        } else if let l = label(t, selected: selected) {
                            Text(l).font(TypeScale.secondary).foregroundStyle(Palette.inkSecondary.color)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(t.name)
                .accessibilityValue(testWords(t) ?? label(t, selected: selected) ?? "")
                .accessibilityHint("Use this server for all traffic that no list names")
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
                RowButton(symbol: "gauge.with.dots.needle.67percent", help: "Test \(t.name)") { Task { await model.testConnectivity(only: t) } }
                    .disabled(model.testing)
                Menu {
                    if t.protocolName == "openvpn" { Button("Edit…") { promptFor = t } }
                    Button("Show Log…") { logsFor = t }
                    Button(t.pinned ? "Unpin" : "Pin to Top") { model.setPinned(t, !t.pinned) }
                    Button(t.note.isEmpty ? "Add Note…" : "Edit Note…") { noting = t }
                    Button("Rename…") { renaming = t }
                    Divider()
                    Button("Remove…", role: .destructive) { confirmRemove = t }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold)).roundGlass(28)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("More for \(t.name)")
            }
            if t.state == .failed, let e = t.error { NoteLine(.error, e) }
            if t.state == .reconnecting, let e = t.error { NoteLine(.warning, e) }
            if let e = model.error("tunnel:\(t.name)") { NoteLine(.error, e) }
        }
        .padding(.vertical, Space.m).padding(.horizontal, Space.l)
    }

    private func testWords(_ t: Tunnel) -> String? {
        guard let r = model.testResults[t.name] else { return nil }
        if case .failed(let why, _) = r { return "\(why): \(r.explanation)" }
        return r.explanation
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
        // Like Shadowrocket: the protocol and its transport, not the server's address. OpenVPN keeps its remote.
        let base = t.protocolName == "openvpn"
            ? [t.protocolLabel, t.serverOverride.nilIfEmpty ?? t.remotes?.first].compactMap { $0 }.joined(separator: ", ")
            : [t.protocolLabel, t.transport].compactMap { $0 }.joined(separator: " / ")
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

/// Edits an OpenVPN server: its sign-in (username, password, private key password, saved in the Keychain if asked) and
/// the server it connects to in place of the profile's, like the server override of OpenVPN's own app. It is also what
/// opens when a server needs its credentials to connect.
struct EditServerSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let tunnel: Tunnel
    @State private var secrets = TunnelSecrets()
    @State private var remember = true
    @State private var server = ""
    @State private var error: String?
    @State private var working = false

    private var asksForCredentials: Bool { tunnel.needsAuth || tunnel.keyEncrypted || tunnel.need == "key" }
    /// Connecting needs the credentials the profile asks for.
    private var canConnect: Bool { !working && (!asksForCredentials || !secrets.isEmpty) }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            header
            Panel {
                if tunnel.needsAuth {
                    FormRow("Username") { TextField("Username", text: $secrets.username).labelsHidden().fieldBox().frame(maxWidth: 280) }
                    Hairline()
                    FormRow("Password") { SecureField("Password", text: $secrets.password).labelsHidden().fieldBox().frame(maxWidth: 280) }
                    Hairline()
                }
                if tunnel.keyEncrypted || tunnel.need == "key" {
                    FormRow("Key password", detail: "Opens the profile's private key.") {
                        SecureField("Private key password", text: $secrets.keyPassword).labelsHidden().fieldBox().frame(maxWidth: 280)
                    }
                    Hairline()
                }
                FormRow("Server", detail: "Replaces the server in the profile. Leave it empty to use the profile's.") {
                    TextField("Server", text: $server, prompt: Text(tunnel.remotes?.first ?? "host:port")).labelsHidden()
                        .font(.system(size: 12.5, design: .monospaced)).fieldBox().frame(maxWidth: 280)
                        .accessibilityLabel("Server override")
                }
                if asksForCredentials {
                    Hairline()
                    FormRow("Save in the Keychain") {
                        Toggle("Save in the Keychain", isOn: $remember).labelsHidden().toggleStyle(.switch).tint(Accent.color)
                    }
                }
            }
            if asksForCredentials {
                Label("Credentials are sent to the service to connect and kept in its memory only while the server is on.", systemImage: "lock.fill")
                    .font(TypeScale.secondary).foregroundStyle(Palette.inkSecondary.color).fixedSize(horizontal: false, vertical: true)
            }
            if let error { NoteLine(.error, error) }
            HStack(spacing: Space.s) {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(OutlineButtonStyle()).keyboardShortcut(.cancelAction)
                if !tunnel.isActive {
                    Button("Save") { Task { await save(connect: false) } }.buttonStyle(OutlineButtonStyle()).disabled(working)
                }
                Button(tunnel.isActive ? "Save" : "Connect") { Task { await save(connect: !tunnel.isActive) } }
                    .buttonStyle(SolidButtonStyle()).keyboardShortcut(.defaultAction)
                    .opacity(tunnel.isActive || canConnect ? 1 : 0.45).disabled(!tunnel.isActive && !canConnect || working)
            }
        }
        .padding(Space.xl)
        .frame(width: 520)
        .font(TypeScale.body)
        .foregroundStyle(Palette.ink.color)
        .onAppear {
            secrets = TunnelKeychain.load(tunnel.name) ?? TunnelSecrets()
            server = tunnel.serverOverride
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
                Text("Edit \(tunnel.name)").font(TypeScale.title).lineLimit(1)
                Text("OpenVPN, \(tunnel.serverOverride.nilIfEmpty ?? tunnel.remotes?.first ?? "no server")")
                    .font(TypeScale.secondary).foregroundStyle(Palette.inkSecondary.color).lineLimit(1)
            }
        }
    }

    private func save(connect: Bool) async {
        working = true
        defer { working = false }
        let s: TunnelSecrets? = asksForCredentials && !secrets.isEmpty ? secrets : nil
        error = await model.saveServerEdit(tunnel, secrets: s, remember: remember, serverOverride: server, connect: connect)
        if error == nil { dismiss() }
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
                Button("Cancel", role: .cancel) { dismiss() }.buttonStyle(OutlineButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Rename") { Task { await save() } }
                    .buttonStyle(SolidButtonStyle()).keyboardShortcut(.defaultAction)
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
                Button("Done") { dismiss() }.buttonStyle(SolidButtonStyle()).keyboardShortcut(.defaultAction)
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
        VStack(alignment: .leading, spacing: Space.l) {
            header
            VStack(alignment: .leading, spacing: Space.m) {
                labeled("Name") {
                    TextField("Name", text: $name, prompt: Text("Subscription")).labelsHidden().fieldBox()
                        .accessibilityLabel("Name")
                }
                labeled("Address", trailing: AnyView(
                    Button { copyAddress() } label: { Label("Copy", systemImage: "doc.on.doc").font(TypeScale.secondary) }
                        .buttonStyle(.plain).foregroundStyle(Palette.inkSecondary.color)
                        .disabled(savedURL == nil).accessibilityLabel("Copy the address")
                )) {
                    TextField("Address", text: $url, prompt: Text(savedURL == nil ? "Reading…" : "https://"), axis: .vertical)
                        .labelsHidden().lineLimit(3...6).font(.system(size: 12, design: .monospaced))
                        .fieldBox().disabled(savedURL == nil)
                        .accessibilityLabel("Subscription address")
                }
                if trimmedURL.hasPrefix("http://") {
                    NoteLine(.error, "Subscriptions must use https://, because the address carries your token.")
                } else {
                    Label("The address carries your token. It stays on this Mac, where only the service can read it, and saving it downloads nothing: use the update button.", systemImage: "lock.fill")
                        .labelStyle(NoteLabelStyle())
                }
            }
            dangerZone
            if let error { NoteLine(.error, error) }
            HStack(spacing: Space.s) {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(OutlineButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Save") { Task { await save() } }
                    .buttonStyle(SolidButtonStyle()).keyboardShortcut(.defaultAction)
                    .opacity(canSave ? 1 : 0.45).disabled(!canSave)
            }
        }
        .padding(Space.xl)
        .frame(width: 520)
        .font(TypeScale.body)
        .foregroundStyle(Palette.ink.color)
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
            Text("Its \(plural(subscription.tunnels, "server")) and the saved address are deleted. A list that uses one of them must be moved to another server first.")
        }
    }

    private var canSave: Bool { changed && !trimmedName.isEmpty && !trimmedURL.isEmpty && !working }

    private var header: some View {
        HStack(spacing: Space.m) {
            ZStack {
                AccentSurface(RoundedRectangle(cornerRadius: Radius.row + 2, style: .continuous))
                Image(systemName: "antenna.radiowaves.left.and.right").font(.system(size: 18, weight: .medium)).foregroundStyle(Color.white)
            }
            .frame(width: 42, height: 42)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Edit subscription").font(TypeScale.title)
                Text(subtitle).font(TypeScale.secondary).foregroundStyle(Palette.inkSecondary.color).lineLimit(1)
            }
        }
    }

    /// "15 servers, updated 2 hours ago".
    private var subtitle: String {
        var parts = [plural(subscription.tunnels, "server")]
        if let d = parseGoTime(subscription.updatedAt) { parts.append("updated \(relative(d))") }
        return parts.joined(separator: ", ")
    }

    private func labeled<C: View>(_ title: String, trailing: AnyView? = nil, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(TypeScale.bodyStrong)
                Spacer()
                if let trailing { trailing }
            }
            content()
        }
    }

    /// Removing is apart from the fields, in its own panel, and asks again.
    private var dangerZone: some View {
        Panel {
            FormRow("Remove subscription", detail: "Deletes its \(plural(subscription.tunnels, "server")) and the saved address.") {
                Button("Remove…", role: .destructive) { confirmRemove = true }
                    .buttonStyle(OutlineButtonStyle()).foregroundStyle(Palette.danger.color).disabled(working)
            }
        }
    }

    private func copyAddress() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
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


/// A line of small print with its icon at the start.
private struct NoteLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            configuration.icon.font(.system(size: 10)).foregroundStyle(Palette.inkSecondary.color)
            configuration.title.font(TypeScale.secondary).foregroundStyle(Palette.inkSecondary.color).fixedSize(horizontal: false, vertical: true)
        }
    }
}


/// A chosen .ovpn file, carried with the sheet that imports it.
struct ProfileChoice: Identifiable {
    let id = UUID()
    let url: URL?
}

/// Which servers the Servers page shows by their last test.
enum LatencyFilter: String, CaseIterable {
    case all, answered, under100, under200, under500

    var title: String {
        switch self {
        case .all: return "All servers"
        case .answered: return "Answered the test"
        case .under100: return "Under 100 ms"
        case .under200: return "Under 200 ms"
        case .under500: return "Under 500 ms"
        }
    }

    /// `all` lets everything through; the others need a result, and a failed one never passes.
    func allows(_ r: TunnelTest?) -> Bool {
        if self == .all { return true }
        guard case .ms(let ms)? = r else { return false }
        switch self {
        case .under100: return ms < 100
        case .under200: return ms < 200
        case .under500: return ms < 500
        default: return true
        }
    }
}

/// Edits a server's note (up to 200 characters).
struct ServerNoteSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let tunnel: Tunnel
    @State private var note = ""
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Space.s) {
                Text("Note for \(tunnel.name)").font(TypeScale.bodyStrong).lineLimit(1)
                TextField("Note", text: $note, prompt: Text("What this server is for").foregroundColor(.secondary), axis: .vertical)
                    .labelsHidden().textFieldStyle(.plain).multilineTextAlignment(.leading).lineLimit(1...4).fieldBox().onSubmit(save)
                Text("\(note.count) of 200").font(TypeScale.secondary).foregroundStyle(note.count > 200 ? Palette.danger.color : Palette.inkSecondary.color).monospacedDigit()
            }
            .padding(Space.xl)
            SheetButtons(error: error) {
                Button("Cancel", role: .cancel) { dismiss() }.buttonStyle(OutlineButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Save", action: save).buttonStyle(SolidButtonStyle()).keyboardShortcut(.defaultAction).disabled(note.count > 200)
            }
        }
        .frame(width: 420)
        .onAppear { note = tunnel.note }
    }

    private func save() {
        error = model.setNote(tunnel, note)
        if error == nil { dismiss() }
    }
}
