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
                Hairline()
                serverRow
                Hairline()
                routingRow
                Hairline()
                killSwitchRow
                Hairline()
                defaultRouteRow
            }
            if model.serviceOutdated {
                Hairline()
                HStack {
                    Text("The service is an older version.").font(TypeScale.secondary).foregroundStyle(Palette.inkSecondary.color)
                    Spacer()
                    Button("Update service") { Task { await model.restartService() } }.buttonStyle(OutlineButtonStyle())
                }
                .padding(.horizontal, Space.l).padding(.vertical, Space.m)
            }
            Hairline()
            MenuItem("Open Splitroute") { openApp(.home) }
            MenuItem("Quit", action: quit)
        }
        .frame(width: 360)
        .font(TypeScale.body)
        .background(Palette.surface.color)
        .background(GeometryReader { g in Color.clear.preference(key: PanelSizeKey.self, value: g.size) })
        .onPreferenceChange(PanelSizeKey.self) { onSize($0) }
    }

    // MARK: Rows

    /// A row: a title and a line under it on the left, the control on the right. Tall enough to hit.
    private func row<C: View>(_ title: String, _ detail: String, dimmed: Bool = false, @ViewBuilder control: () -> C) -> some View {
        HStack(spacing: Space.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(TypeScale.bodyStrong).foregroundStyle(Palette.ink.color)
                Text(detail).font(TypeScale.secondary).foregroundStyle(Palette.inkSecondary.color).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Space.s)
            control()
        }
        .padding(.horizontal, Space.l).padding(.vertical, 14)
        .frame(minHeight: 56)
        .opacity(dimmed ? 0.45 : 1) // one fade for the whole row, like the cards on Home
        .animation(.easeOut(duration: 0.25), value: dimmed)
        .allowsHitTesting(!dimmed)
    }

    private var connectionRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            row("Connection", model.summary) {
                Toggle("Connection", isOn: Binding(get: { model.vpnOn }, set: { on in
                    Task {
                        await model.setVPN(on)
                        // The selected OpenVPN server needs a password: the sheet for it is in the app.
                        if on, let t = model.selectedTunnel, t.state == .needsAuth, model.needsCredentialPrompt(t) { openApp(.tunnels) }
                    }
                }))
                .labelsHidden().toggleStyle(.switch).tint(Accent.color)
                .accessibilityLabel("Connection")
            }
            if let e = model.error("vpn") { NoteLine(.error, e).padding(.horizontal, Space.l).padding(.bottom, Space.m) }
        }
    }

    /// The server that carries the traffic, and the way to choose another. Always available, connected or not.
    private var serverRow: some View {
        let names = model.tunnels.map(\.name)
        let selected = model.tunnelList?.selected
        return row("Server", selected == nil ? "None selected" : "Carries your traffic") {
            SelectMenu(title: selected ?? "Choose…", options: names, label: { $0 }, selected: selected,
                       group: { n in model.tunnels.first { $0.name == n }?.group }) { n in
                Task { if let t = model.tunnels.first(where: { $0.name == n }), await model.selectTunnel(t) { openApp(.tunnels) } }
            }
            .accessibilityLabel("Server")
        }
    }

    private var routingRow: some View {
        row("Routing", model.routingOn ? "Lists are applied" : "Only the default route is applied", dimmed: !connected) {
            Toggle("Routing", isOn: Binding(get: { model.routingOn }, set: { on in Task { await model.setRoutingOn(on) } }))
                .labelsHidden().toggleStyle(.switch).tint(Accent.color)
                .accessibilityLabel("Routing")
        }
    }

    private var killSwitchRow: some View {
        let detail = model.killSwitchOn ? (model.killSwitchArmed ? "Blocking leaks" : "Not active") : "Off"
        return row("Kill Switch", detail, dimmed: !connected) {
            Toggle("Kill Switch", isOn: Binding(get: { model.killSwitchOn }, set: { on in Task { await model.setKillSwitch(on: on) } }))
                .labelsHidden().toggleStyle(.switch).tint(Accent.color)
                .accessibilityLabel("Kill Switch")
        }
    }

    private var defaultRouteRow: some View {
        row("Default Route", "Traffic that matches no list", dimmed: !connected) { DefaultRouteMenu() }
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

private struct PanelSizeKey: PreferenceKey {
    static var defaultValue = CGSize.zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

/// A full-width item under the rows: the whole line is the button, with a highlight under the pointer.
private struct MenuItem: View {
    let title: String
    let action: () -> Void
    @State private var hover = false

    init(_ title: String, action: @escaping () -> Void) { self.title = title; self.action = action }

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title).font(TypeScale.body).foregroundStyle(Palette.ink.color)
                Spacer()
            }
            .padding(.horizontal, Space.l)
            .frame(height: 44)
            .background(hover ? Color.primary.opacity(0.08) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
