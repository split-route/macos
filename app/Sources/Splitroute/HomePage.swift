import Charts
import Design
import SwiftUI

/// The first page: is the engine on, through which server, what the kill switch and the default route are doing, and
/// how fast traffic moves. Information only; the Servers page has the switch.
struct HomePage: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var traffic: TrafficMonitor
    /// Opens another page: the Server and Default Route cards link to theirs.
    let go: (Destination) -> Void

    private var connected: Bool { model.health == .active }

    private var finalText: String {
        switch model.config?.finalAction ?? .tunnel {
        case .direct: return "Direct"
        case .block: return "Block"
        default: return model.config?.finalTunnel ?? "Active Server"
        }
    }

    private var finalDot: Color {
        switch model.config?.finalAction ?? .tunnel {
        case .direct: return Palette.success.color
        case .block: return Palette.danger.color
        default: return Accent.color
        }
    }



    private var killSwitch: (text: String, dot: Color) {
        guard model.killSwitchOn else { return ("Off", Palette.inkSecondary.color.opacity(0.5)) }
        return model.killSwitchArmed ? ("Active", Palette.success.color) : ("Not active", Palette.warning.color)
    }

    var body: some View {
        PageScaffold("Home") {
            EmptyView()
        } content: {
            if !model.ready {
                ServiceUnavailable()
            } else {
                VStack(alignment: .leading, spacing: Space.l) {
                    statusCard
                    HStack(spacing: Space.m) {
                        Tile(title: "Routing", value: model.routingOn ? "On" : "Off", symbol: "arrow.triangle.branch", dot: model.routingOn ? Palette.success.color : Palette.inkSecondary.color.opacity(0.5),
                             isOn: Binding(get: { model.routingOn }, set: { on in Task { await model.setRoutingOn(on) } }), dimmed: !connected)
                        Tile(title: "Default Route", value: finalText, symbol: "arrow.triangle.branch", dot: finalDot,
                             open: { go(.lists) }, dimmed: !connected)
                        Tile(title: "Kill switch", value: killSwitch.text, symbol: "hand.raised", dot: killSwitch.dot,
                             isOn: Binding(get: { model.killSwitchOn }, set: { on in Task { await model.setKillSwitch(on: on) } }), dimmed: !connected)
                    }
                    HStack(spacing: Space.m) {
                        Tile(title: "Server", value: model.selectedTunnel?.name ?? "None selected", symbol: "shield", dot: nil,
                             open: { go(.tunnels) }, dimmed: !connected)
                        Tile(title: "Download", value: connected ? speedText(traffic.current?.down ?? 0) : "—", symbol: "arrow.down", dot: nil,
                             tone: Palette.success.color, dimmed: !connected)
                        Tile(title: "Upload", value: connected ? speedText(traffic.current?.up ?? 0) : "—", symbol: "arrow.up", dot: nil,
                             tone: Palette.warning.color, dimmed: !connected)
                    }
                    SpeedChart(samples: traffic.samples, live: connected)
                }
            }
        }
    }

    /// Under the title: why, not the title again.
    private var subtitle: String {
        if model.connError != nil { return model.summary }
        if model.vpnOn { return model.sidebarStatus }
        return model.selectedTunnel.map { "Will connect through \($0.name)" } ?? "Select a server first"
    }

    private var statusCard: some View {
        Panel {
            HStack(spacing: Space.l) {
                Image(systemName: connected ? "checkmark.shield.fill" : "shield.slash")
                    .font(.system(size: 34))
                    .foregroundStyle(connected ? Accent.color : Palette.inkSecondary.color)
                    .contentTransition(.symbolEffect(.replace))
                    .animation(.easeOut(duration: 0.25), value: connected)
                    .frame(width: 52)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(connected ? "Connected" : "Disconnected").font(TypeScale.title).foregroundStyle(Palette.ink.color)
                        .contentTransition(.opacity).animation(.easeOut(duration: 0.2), value: connected)
                    Text(subtitle).font(TypeScale.body)
                        .foregroundStyle(Palette.inkSecondary.color).lineLimit(2)
                }
                Spacer()
                Toggle("Connection", isOn: Binding(get: { model.vpnOn }, set: { on in
                    Task {
                        await model.setVPN(on)
                        // The selected server needs a password: the sheet for it is on the Servers page.
                        if on, let t = model.selectedTunnel, t.state == .needsAuth, model.needsCredentialPrompt(t) { go(.tunnels) }
                    }
                }))
                .labelsHidden().toggleStyle(.switch).tint(Accent.color)
                .disabled(model.tunnels.isEmpty)
                .accessibilityLabel("Connection")
            }
            .padding(Space.l)
            if let e = model.status?.error { NoteLine(.error, e).padding([.horizontal, .bottom], Space.l) } // the engine's own problem
            if let e = model.error("vpn") { NoteLine(.error, e).padding([.horizontal, .bottom], Space.l) }
        }
    }
}

/// One figure on the dashboard.
private struct Tile: View {
    let title: String
    let value: String
    let symbol: String
    let dot: Color?
    var tone: Color = Palette.inkSecondary.color
    /// A card that opens a page when clicked.
    var open: (() -> Void)?
    /// A card with a switch.
    var isOn: Binding<Bool>?
    /// Not connected: the card stays but is faded and does nothing (no link, no switch), so it's clear to connect first.
    var dimmed = false

    var body: some View {
        // Dimmed: no button at all, so the only fading is ours. A disabled button or switch fades itself on top of it,
        // and the cards would not match.
        if let open, !dimmed {
            Button(action: open) { card }
                .buttonStyle(.plain)
                .accessibilityHint("Opens the page")
        } else {
            card
        }
    }

    private var card: some View {
        HStack(alignment: .center, spacing: Space.s) {
            VStack(alignment: .leading, spacing: Space.s) {
                HStack(spacing: 6) {
                    Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(tone)
                    Text(title).font(TypeScale.secondary).foregroundStyle(Palette.inkSecondary.color)
                }
                HStack(spacing: 8) {
                    if let dot { Circle().fill(dot).frame(width: 8, height: 8) }
                    Text(value).font(TypeScale.heading).foregroundStyle(Palette.ink.color).lineLimit(1).monospacedDigit()
                }
            }
            Spacer(minLength: 0)
            if let isOn {
                Toggle(title, isOn: isOn).labelsHidden().toggleStyle(.switch).tint(Accent.color).controlSize(.small)
                    .allowsHitTesting(!dimmed).focusable(!dimmed)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Space.l)
        .background(Glass.fill)
        .clipShape(RoundedRectangle(cornerRadius: Radius.panel))
        .overlay(RoundedRectangle(cornerRadius: Radius.panel).stroke(Glass.stroke, lineWidth: 1))
        .opacity(dimmed ? 0.45 : 1)
        .animation(.easeOut(duration: 0.25), value: dimmed)
        .contentShape(RoundedRectangle(cornerRadius: Radius.panel))
        .accessibilityElement(children: isOn == nil ? .combine : .contain)
    }
}

/// The last minute of speed: download in green, upload in orange, a dashed grid, the scale's top at the right.
private struct SpeedChart: View {
    let samples: [TrafficMonitor.Sample]
    /// Connected: the lines are drawn. Not: the chart stays, faded and empty.
    let live: Bool

    /// The top of the scale: the biggest speed seen, rounded up, never below 10 KB/s so a quiet line stays flat.
    private var top: Double {
        let peak = samples.map { max($0.down, $0.up) }.max() ?? 0
        let steps: [Double] = [10e3, 50e3, 100e3, 500e3, 1e6, 5e6, 10e6, 50e6, 100e6, 500e6, 1e9]
        return steps.first { $0 >= peak * 1.1 } ?? peak * 1.1
    }

    private var start: Date { (samples.last?.time ?? Date()).addingTimeInterval(-Double(TrafficMonitor.window)) }

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: Space.m) {
                Chart {
                    ForEach(live ? samples : []) { s in
                        LineMark(x: .value("Time", s.time), y: .value("Speed", s.down), series: .value("Direction", "Download"))
                            .interpolationMethod(.catmullRom).foregroundStyle(Palette.success.color)
                            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                        LineMark(x: .value("Time", s.time), y: .value("Speed", s.up), series: .value("Direction", "Upload"))
                            .interpolationMethod(.catmullRom).foregroundStyle(Palette.warning.color)
                            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                    }
                }
                .chartXScale(domain: start...(samples.last?.time ?? Date()))
                .chartYScale(domain: 0...top)
                .chartXAxis(.hidden)
                .chartYAxis {
                    AxisMarks(values: [0, top / 3, top * 2 / 3, top]) { v in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 1, dash: v.index == 0 ? [] : [4, 4])).foregroundStyle(Glass.divider)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    Text(speedText(top)).font(TypeScale.secondary).monospacedDigit()
                        .foregroundStyle(Palette.inkSecondary.color).padding(.trailing, 2)
                }
                .frame(height: 190)
                .accessibilityLabel("Speed over the last minute")
                .accessibilityValue(live ? "Download \(speedText(samples.last?.down ?? 0)), upload \(speedText(samples.last?.up ?? 0))" : "Not connected")
                HStack(spacing: Space.xl) {
                    legend("arrow.down.circle", live ? speedText(samples.last?.down ?? 0) : "—", Palette.success.color)
                    legend("arrow.up.circle", live ? speedText(samples.last?.up ?? 0) : "—", Palette.warning.color)
                    Spacer()
                    Text("Last minute").font(TypeScale.secondary).foregroundStyle(Palette.inkSecondary.color)
                }
            }
            .padding(Space.l)
        }
        .opacity(live ? 1 : 0.45) // the whole panel, like the cards
        .animation(.easeOut(duration: 0.25), value: live)
    }

    private func legend(_ symbol: String, _ text: String, _ color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(text).font(TypeScale.bodyStrong).monospacedDigit().foregroundStyle(color)
        }
    }
}
