import Design
import SwiftUI

/// The menu bar panel: the connection switch, the kill switch, the default route, and the way to the window or out.
/// Anything that needs a sheet (credentials) opens the window on the right page.
struct MenuPopover: View {
    @EnvironmentObject private var model: AppModel
    let openApp: (Destination) -> Void
    let quit: () -> Void
    /// Reports the content's size, so the panel around it can follow when a row appears or goes.
    var onSize: (CGSize) -> Void = { _ in }

    private var connected: Bool { model.health == .active }

    /// A long server name is cut short here so the words next to it keep one line.
    private static let controlTitleWidth: CGFloat = 130

    var body: some View {
        VStack(spacing: 0) {
            if model.connError != nil {
                notice
            } else if model.tunnels.isEmpty {
                VStack(spacing: Space.s) {
                    Text("No servers yet").font(TypeScale.heading).foregroundStyle(Palette.ink.color)
                    Text("Add one to start routing.").font(TypeScale.secondary).foregroundStyle(Palette.inkSecondary.color)
                    Button("Add servers") { openApp(.tunnels) }.buttonStyle(SolidButtonStyle()).padding(.top, 4)
                }
                .frame(maxWidth: .infinity).padding(.vertical, Space.xl)
            } else {
                connectionRow
                serverRow
                routingRow
                killSwitchRow
                defaultRouteRow
            }
            if model.serviceOutdated {
                HStack {
                    Text("The service is an older version.").font(TypeScale.secondary).foregroundStyle(Palette.inkSecondary.color)
                    Spacer()
                    Button("Update service") { Task { await model.restartService() } }.buttonStyle(OutlineButtonStyle())
                }
                .padding(.horizontal, Space.l).padding(.vertical, Space.m)
            }
            if let v = model.stagedUpdate {
                // Only once it is downloaded and checked: installing is the next step.
                MenuItem("Install newer version (\(v))", dot: Palette.success.color) { model.confirmingInstall = true; openApp(.general) }
            } else if let r = model.newerRelease {
                MenuItem("Newer version is available (\(r.version))", dot: Palette.success.color) { openApp(.general) }
            }
            MenuItem("Open Splitroute") { openApp(.home) }
            MenuItem("Quit", action: quit)
        }
        .frame(width: 320)
        .font(TypeScale.body)
        .background(PanelGlass())
        .background(GeometryReader { g in Color.clear.preference(key: PanelSizeKey.self, value: g.size) })
        .onPreferenceChange(PanelSizeKey.self) { onSize($0) }
    }

    // MARK: Rows

    /// A row: the title on the left, the control on the right. The state line is a tooltip and the accessibility value, not shown.
    private func row<C: View>(_ title: String, _ detail: String, dimmed: Bool = false, @ViewBuilder control: () -> C) -> some View {
        HStack(spacing: Space.m) {
            Text(title).font(TypeScale.bodyStrong).foregroundStyle(Palette.ink.color)
                .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1) // the title gets its room first; the control takes what is left
            Spacer(minLength: Space.s)
            control()
        }
        .padding(.horizontal, Space.l).padding(.vertical, 8)
        .frame(minHeight: 42)
        .help(detail)
        .accessibilityValue(detail)
        .opacity(dimmed ? 0.45 : 1) // one fade for the whole row, like the cards on Home
        .animation(.easeOut(duration: 0.25), value: dimmed)
        .allowsHitTesting(!dimmed)
    }

    private var connectionRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            row("Connection", model.summary) {
                PendingToggle("Connection", isOn: Binding(get: { model.vpnOn }, set: { on in
                    Task {
                        await model.setVPN(on)
                        // The selected OpenVPN server needs a password: the sheet for it is in the app.
                        if on, let t = model.selectedTunnel, t.state == .needsAuth, model.needsCredentialPrompt(t) { openApp(.tunnels) }
                    }
                }), pending: model.pending.contains("vpn"))
            }
            if let e = model.error("vpn") { NoteLine(.error, e).padding(.horizontal, Space.l).padding(.bottom, Space.m) }
        }
    }

    /// The server that carries the traffic, and the way to choose another. Always available, connected or not.
    private var serverRow: some View {
        let names = model.tunnelNamesLocalFirst
        let selected = model.tunnelList?.selected
        return row("Server", selected == nil ? "None selected" : "Carries your traffic") {
            HStack(spacing: 6) {
                SelectMenu(title: selected ?? "Choose…", options: names, label: { serverLabel($0) }, selected: selected,
                           group: { n in model.tunnels.first { $0.name == n }?.group }, maxTitleWidth: Self.controlTitleWidth, compact: true) { n in
                    Task { if let t = model.tunnels.first(where: { $0.name == n }), await model.selectTunnel(t) { openApp(.tunnels) } }
                }
                .accessibilityLabel("Server")
                Button { Task { await model.testConnectivity() } } label: {
                    Group {
                        if model.testing { ProgressView().controlSize(.small) } else { Image(systemName: "gauge.with.dots.needle.67percent").font(.system(size: 11, weight: .semibold)) }
                    }
                    .foregroundStyle(Palette.ink.color).roundGlass(26)
                }
                .buttonStyle(.plain).disabled(model.testing || names.isEmpty)
                .help("Test every server's latency").accessibilityLabel("Test servers")
            }
        }
    }

    /// A server's name in the list: a flag it points to, and how fast it answered the last test.
    private func serverLabel(_ name: String) -> String {
        let t = model.tunnels.first { $0.name == name }
        let flag = Flags.prefix(for: [name, t?.group]).map { $0 + " " } ?? ""
        switch model.testResults[name] {
        case .ms(let ms)?: return "\(flag)\(name)  ·  \(ms) ms"
        case .failed(let why, _)?: return "\(flag)\(name)  ·  \(why)"
        case nil: return flag + name
        }
    }

    private var routingRow: some View {
        row("Routing", model.routingOn ? "Lists are applied" : "Only the default route is applied", dimmed: !connected) {
            PendingToggle("Routing", isOn: Binding(get: { model.routingOn }, set: { on in Task { await model.setRoutingOn(on) } }),
                          pending: model.pending.contains("routing"))
        }
    }

    private var killSwitchRow: some View {
        let detail = model.killSwitchOn ? (model.killSwitchArmed ? "Blocking leaks" : "Not active") : "Off"
        return row("Kill Switch", detail, dimmed: !connected) {
            PendingToggle("Kill Switch", isOn: Binding(get: { model.killSwitchOn }, set: { on in Task { await model.setKillSwitch(on: on) } }),
                          pending: model.pending.contains("killswitch"))
        }
    }

    private var defaultRouteRow: some View {
        row("Default Route", "When no list matches", dimmed: !connected) { DefaultRouteMenu(maxTitleWidth: Self.controlTitleWidth, compact: true) }
    }

    /// The service can't be reached: the way to fix it, as the old menu offered.
    @ViewBuilder private var notice: some View {
        VStack(spacing: Space.s) {
            Text(model.connError?.localizedDescription ?? "Connecting…").font(TypeScale.heading)
                .foregroundStyle(Palette.ink.color).multilineTextAlignment(.center)
            if model.serviceNeedsApproval {
                Button("Allow in Login Items") { model.openLoginItems() }.buttonStyle(SolidButtonStyle())
            } else if model.connError == .notRunning {
                Button("Install service") { Task { await model.installService() } }
                    .buttonStyle(SolidButtonStyle()).disabled(model.busy)
            }
        }
        .frame(maxWidth: .infinity).padding(Space.xl)
    }
}

/// The panel's body: Liquid Glass on macOS 26+, a blurred material before. The panel window is clear, so this is all
/// the backdrop there is.
private struct PanelGlass: View {
    @Environment(\.colorScheme) private var scheme
    /// How much of the tint covers the glass: higher is less see-through.
    private static let tint = 0.55

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: MenuBarPanel.cornerRadius, style: .continuous)
        ZStack {
            if #available(macOS 26, *) {
                Color.clear.glassEffect(.regular, in: shape)
            } else {
                shape.fill(.ultraThinMaterial)
            }
            // Glass alone shows the windows behind it; the tint keeps them from competing with the text.
            shape.fill(scheme == .dark ? Color.black.opacity(Self.tint) : Color.white.opacity(Self.tint))
        }
    }
}

private struct PanelSizeKey: PreferenceKey {
    static var defaultValue = CGSize.zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

/// A full-width item under the rows: the whole line is the button, with a highlight under the pointer.
private struct MenuItem: View {
    let title: String
    var dot: Color?
    let action: () -> Void
    @State private var hover = false

    init(_ title: String, dot: Color? = nil, action: @escaping () -> Void) { self.title = title; self.dot = dot; self.action = action }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.s) {
                if let dot { Circle().fill(dot).frame(width: 8, height: 8).accessibilityHidden(true) }
                Text(title).font(TypeScale.body).foregroundStyle(Palette.ink.color)
                Spacer()
            }
            .padding(.horizontal, Space.l)
            .frame(height: 38)
            .background(hover ? Color.primary.opacity(0.08) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
