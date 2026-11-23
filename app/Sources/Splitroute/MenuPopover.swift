import Design
import SwiftUI

/// The menu bar popover: tunnels with their Connect buttons, the first lists with
/// where each goes, and the way to the window. Anything that needs a sheet
/// (credentials) opens the window on the right page.
struct MenuPopover: View {
    @EnvironmentObject private var model: AppModel
    let openApp: (Destination) -> Void
    let quit: () -> Void

    private var lists: [RouteList] { Array((model.config?.lists ?? []).prefix(4)) }

    private var selectedName: String? { model.tunnelList?.selected }

    var body: some View {
        VStack(spacing: 0) {
            if model.connError != nil {
                notice
            } else if model.tunnels.isEmpty {
                VStack(spacing: Space.s) {
                    Text("No tunnels yet").font(TypeScale.heading).foregroundStyle(Palette.ink.color)
                    Text("Add one to start routing.").font(TypeScale.secondary).foregroundStyle(Palette.inkSecondary.color)
                    Button("Add tunnels") { openApp(.tunnels) }.buttonStyle(SolidButtonStyle()).padding(.top, 4)
                }
                .frame(maxWidth: .infinity).padding(.vertical, Space.xl)
            } else {
                switchRow
                Hairline()
                tunnelRow
                if !lists.isEmpty {
                    Hairline()
                    ForEach(lists) { l in listRow(l) }
                }
            }
            if model.serviceOutdated {
                Hairline()
                HStack {
                    Text("The service is an older version.").font(TypeScale.secondary).foregroundStyle(Palette.inkSecondary.color)
                    Spacer()
                    Button("Update service") { Task { await model.restartService() } }.buttonStyle(OutlineButtonStyle())
                }
                .padding(.horizontal, Space.l).padding(.vertical, 10)
            }
            Hairline()
            HStack {
                Button("Open Splitroute") { openApp(.tunnels) }
                    .buttonStyle(.plain).font(TypeScale.bodyStrong).foregroundStyle(Palette.ink.color)
                Spacer()
                Button("Quit", action: quit)
                    .buttonStyle(.plain).font(TypeScale.body).foregroundStyle(Palette.inkSecondary.color)
            }
            .padding(.horizontal, Space.l).padding(.vertical, 10)
        }
        .frame(width: 340)
        .font(TypeScale.body)
        .background(Palette.surface.color)
    }

    /// The one switch, with what the VPN is doing in a sentence.
    private var switchRow: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(spacing: Space.m) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("VPN").font(TypeScale.heading).foregroundStyle(Palette.ink.color)
                    Text(model.summary).font(TypeScale.secondary).foregroundStyle(Palette.inkSecondary.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Space.s)
                Toggle("VPN", isOn: Binding(get: { model.vpnOn }, set: { on in
                    Task {
                        await model.setVPN(on)
                        // The selected OpenVPN tunnel needs a password: the sheet for it is in the app.
                        if on, let t = model.selectedTunnel, t.state == .needsAuth, model.needsCredentialPrompt(t) { openApp(.tunnels) }
                    }
                }))
                .labelsHidden().toggleStyle(.switch).tint(Accent.color)
                .accessibilityLabel("VPN")
            }
            if let e = model.error("vpn") { NoteLine(.error, e) }
        }
        .padding(.horizontal, Space.l).padding(.vertical, Space.m)
    }

    /// The tunnel that carries the traffic, and the way to choose another.
    private var tunnelRow: some View {
        HStack(spacing: Space.m) {
            Text("Tunnel").font(TypeScale.body).foregroundStyle(Palette.inkSecondary.color)
            Spacer(minLength: Space.s)
            Menu {
                ForEach(groupedNames, id: \.title) { g in
                    if let title = g.title {
                        Section(title) { choices(g.tunnels) }
                    } else {
                        choices(g.tunnels)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(selectedName ?? "Choose…").font(TypeScale.bodyStrong).lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Palette.inkSecondary.color)
                }
                .foregroundStyle(Palette.ink.color)
                .contentShape(Rectangle())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
            .accessibilityLabel("Tunnel for all traffic that no list names")
        }
        .padding(.horizontal, Space.l).padding(.vertical, 10)
    }

    private struct NamedGroup { var title: String?; var tunnels: [Tunnel] }

    /// The tunnels, the ones you added first and then one section per subscription.
    private var groupedNames: [NamedGroup] {
        var out = [NamedGroup(title: nil, tunnels: model.tunnels.filter { $0.group == nil })]
        for sub in model.tunnelList?.subscriptions ?? [] {
            out.append(NamedGroup(title: sub.name, tunnels: model.tunnels.filter { $0.group == sub.name }))
        }
        return out.filter { !$0.tunnels.isEmpty }
    }

    @ViewBuilder private func choices(_ ts: [Tunnel]) -> some View {
        ForEach(ts) { t in
            Button {
                Task { if await model.selectTunnel(t) { openApp(.tunnels) } }
            } label: {
                if t.name == selectedName { Label(t.name, systemImage: "checkmark") } else { Text(t.name) }
            }
        }
    }

    private func listRow(_ l: RouteList) -> some View {
        let dot: Color
        switch l.action {
        case .direct: dot = Palette.ink.color
        case .block: dot = Palette.danger.color
        case .tunnel: dot = Palette.inkSecondary.color
        }
        let text = l.action == .tunnel ? (l.tunnel ?? "Selected tunnel") : l.action.label
        return HStack {
            Text(model.info(l.name)?.title ?? l.name).font(TypeScale.body).foregroundStyle(Palette.ink.color).lineLimit(1)
            Spacer(minLength: Space.s)
            HStack(spacing: 6) {
                Circle().fill(dot).frame(width: 7, height: 7)
                Text(text).font(TypeScale.secondary).foregroundStyle(Palette.inkSecondary.color).lineLimit(1)
            }
        }
        .padding(.horizontal, Space.l).padding(.vertical, 6)
        .accessibilityElement(children: .combine)
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
