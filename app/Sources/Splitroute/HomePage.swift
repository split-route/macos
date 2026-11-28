import Charts
import Design
import SwiftUI

/// The first page: is the engine on, through which server, what the kill switch and the default route are doing, and
/// how fast traffic moves. Information only; the Servers page has the switch.
struct HomePage: View {
    /// The chart takes what the cards above leave of the window, never less than 190 pt. 420 is those cards, the title and
    /// the page's margins, a little over, so a window at its default size doesn't scroll.
    @Environment(\.pageViewportHeight) private var viewport
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



    private var serverText: String {
        guard let t = model.selectedTunnel else { return "None selected" }
        return (Flags.prefix(name: t.name, country: t.country).map { $0 + " " } ?? "") + t.name
    }

    /// The address the world sees through the server, with its country's flag; a dash until it is known.
    private var ipText: String {
        guard connected else { return "—" }
        guard let i = model.exitInfo else { return model.exitLookupFailed ? "Unavailable" : "Looking up…" }
        return (i.code.map { Flags.emoji(code: $0) + " " } ?? "") + i.ip
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
                             isOn: Binding(get: { model.routingOn }, set: { on in if !on && !model.confirmRoutingOff() { return }; Task { await model.setRoutingOn(on) } }), pending: model.pending.contains("routing"), dimmed: !connected, tint: model.routingOn ? Palette.success.color : nil)
                        Tile(title: "Default Route", value: finalText, symbol: "arrow.triangle.branch", dot: finalDot,
                             open: { go(.lists) }, dimmed: !connected, tint: finalDot)
                        Tile(title: "Kill switch", value: killSwitch.text, symbol: "hand.raised", dot: killSwitch.dot,
                             isOn: Binding(get: { model.killSwitchOn }, set: { on in if !on && !model.confirmKillSwitchOff() { return }; Task { await model.setKillSwitch(on: on) } }), pending: model.pending.contains("killswitch"), dimmed: !connected, tint: model.killSwitchOn ? killSwitch.dot : nil)
                    }
                    HStack(spacing: Space.m) {
                        Tile(title: "Server", value: serverText, symbol: "shield", dot: nil,
                             open: { go(.tunnels) }, dimmed: !connected, tint: Accent.color)
                        Tile(title: "IP address", value: ipText, symbol: "globe", dot: nil,
                             dimmed: !connected, tint: Accent.color)
                            .help(model.exitInfo.map { $0.country } ?? "")
                    }
                    SpeedChart(samples: traffic.samples, live: connected, height: max(190, viewport - 420))
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

    private var vpnBinding: Binding<Bool> {
        Binding(get: { model.vpnOn }, set: { on in
            if !on && !model.confirmDisconnect() { return }
            Task {
                await model.setVPN(on)
                // The selected server needs a password: the sheet for it is on the Servers page.
                if on, let t = model.selectedTunnel, t.state == .needsAuth, model.needsCredentialPrompt(t) { go(.tunnels) }
            }
        })
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
                    ConnectionLine(fallback: subtitle).font(TypeScale.body)
                        .foregroundStyle(Palette.inkSecondary.color).lineLimit(2)
                }
                Spacer()
                PendingToggle("Connection", isOn: vpnBinding, pending: model.pending.contains("vpn"))
                    .disabled(model.tunnels.isEmpty)
            }
            .padding(.horizontal, Space.l).padding(.vertical, Space.xl)
            .tapToToggle(vpnBinding, pending: model.pending.contains("vpn"), enabled: !model.tunnels.isEmpty)
            .background(alignment: .top) {
                // The same wash the cards below have: the accent while connected, nothing while not.
                LinearGradient(colors: [Accent.color.opacity(connected ? 0.20 : 0), .clear], startPoint: .top, endPoint: .bottom)
                    .animation(.easeOut(duration: 0.25), value: connected)
            }
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
    /// The switch's change is being applied: it shows a spinner.
    var pending = false
    /// Not connected: the card stays but is faded and does nothing (no link, no switch), so it's clear to connect first.
    var dimmed = false
    /// A faint wash of this colour at the card's top, so a card's state reads before its words do.
    var tint: Color?

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
                PendingToggle(title, isOn: isOn, pending: pending)
                    .allowsHitTesting(!dimmed).focusable(!dimmed)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Space.l)
        .background(Glass.fill)
        .background(alignment: .top) {
            if let tint { LinearGradient(colors: [tint.opacity(0.16), .clear], startPoint: .top, endPoint: .center) }
        }
        .clipShape(RoundedRectangle(cornerRadius: Radius.panel))
        .overlay(RoundedRectangle(cornerRadius: Radius.panel).stroke(Glass.stroke, lineWidth: 1))
        .opacity(dimmed ? 0.45 : 1)
        .animation(.easeOut(duration: 0.25), value: dimmed)
        .contentShape(RoundedRectangle(cornerRadius: Radius.panel))
        .tapToToggle(isOn, pending: pending, enabled: !dimmed) // the whole card is the switch
        .accessibilityElement(children: isOn == nil ? .combine : .contain)
    }
}

/// The last minute of speed: download in green, upload in orange, a dashed grid, the scale's top at the right.
private struct SpeedChart: View {
    let samples: [TrafficMonitor.Sample]
    /// Connected: the lines are drawn. Not: the chart stays, faded and empty.
    let live: Bool
    let height: CGFloat

    /// The top of the scale: the biggest speed seen plus a margin, rounded up to a round number.
    private var top: Double { TrafficMonitor.niceTop(samples.map { max($0.down, $0.up) }.max() ?? 0) }

    /// How far below zero the chart goes: a third of the way up, in the units of `level`, is a quarter of its height of room.
    private static let floor = -1.0 / 3

    /// A speed as its height on the chart, from 0 to 1: the square root of its share of the top, so a quiet line keeps room above
    /// the baseline beside a big peak.
    private func level(_ speed: Double) -> Double { (min(max(speed / top, 0), 1)).squareRoot() }

    /// What is drawn: the samples smoothed, so a one-second spike is a hill.
    private var drawn: [TrafficMonitor.Sample] { TrafficMonitor.smoothed(samples) }

    /// A point of the chart: the height of each line there.
    private struct Level: Identifiable {
        let time: Date
        let down: Double
        let up: Double
        var id: Date { time }
    }

    /// The heights to draw. A line that begins inside the chart (the connection, or the window, is new) starts at the bottom three
    /// seconds before its first sample and rises smoothly to the baseline, instead of beginning in mid-air.
    private var plotted: [Level] {
        var out = drawn.map { Level(time: $0.time, down: level($0.down), up: level($0.up)) }
        if let first = drawn.first, first.time.timeIntervalSince(start) > 2 {
            out.insert(Level(time: first.time.addingTimeInterval(-3), down: Self.floor, up: Self.floor), at: 0)
        }
        return out
    }

    /// Where a time is across the chart's width at `now`: the window is the minute ending `lag` ago.
    private static func x(_ t: Date, now: Date, width: CGFloat) -> CGFloat {
        let end = now.addingTimeInterval(-lag)
        return width * CGFloat(1 - end.timeIntervalSince(t) / Double(TrafficMonitor.window))
    }

    /// The heights eased so far, by sample time: each moves toward its target at its own pace and a new point starts at its target.
    private final class Easer {
        var cur: [Date: (down: Double, up: Double)] = [:]
        var last: Date?
    }
    @State private var easer = Easer()

    private func drawChart(_ ctx: inout GraphicsContext, _ size: CGSize, now: Date) {
        func y(_ v: Double) -> CGFloat { size.height * CGFloat(1 - (v - Self.floor) / (1 - Self.floor)) }
        // The grid: zero is solid; above it, evenly spaced on the square-root scale, a ninth and four ninths of the top, and the top.
        for v in [0, 1.0 / 3, 2.0 / 3, 1.0] {
            var line = Path(); line.move(to: CGPoint(x: 0, y: y(v))); line.addLine(to: CGPoint(x: size.width, y: y(v)))
            ctx.stroke(line, with: .color(Glass.divider), style: StrokeStyle(lineWidth: 1, dash: v == 0 ? [] : [4, 4]))
        }
        guard live, !plotted.isEmpty else { easer.cur = [:]; easer.last = nil; return }
        let k = easer.last.map { 1 - exp(-now.timeIntervalSince($0) / 0.25) } ?? 1
        easer.last = now
        var next: [Date: (down: Double, up: Double)] = [:]
        let pts = plotted.map { t -> (t: Date, down: Double, up: Double) in
            let c = easer.cur[t.time] ?? (t.down, t.up)
            let v = (down: c.down + (t.down - c.down) * k, up: c.up + (t.up - c.up) * k)
            next[t.time] = v
            return (t.time, v.down, v.up)
        }
        easer.cur = next
        for download in [true, false] {
            let color = download ? Palette.success.color : Palette.warning.color
            let top = download ? 0.42 : 0.32, bottom = download ? 0.03 : 0.02
            let points = pts.map { CGPoint(x: Self.x($0.t, now: now, width: size.width), y: y(download ? $0.down : $0.up)) }
            let line = Self.curve(points)
            var area = line
            if let f = points.first, let l = points.last {
                area.addLine(to: CGPoint(x: l.x, y: size.height)); area.addLine(to: CGPoint(x: f.x, y: size.height)); area.closeSubpath()
            }
            ctx.fill(area, with: .linearGradient(Gradient(colors: [color.opacity(top), color.opacity(bottom)]),
                                                 startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: size.height)))
            ctx.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
    }

    /// A Catmull-Rom curve through the points (each segment a cubic Bezier with the neighbors' slope), the shape Charts drew.
    private static func curve(_ p: [CGPoint]) -> Path {
        var path = Path()
        guard let first = p.first else { return path }
        path.move(to: first)
        for i in 0..<max(p.count - 1, 0) {
            let p0 = p[max(i - 1, 0)], p1 = p[i], p2 = p[i + 1], p3 = p[min(i + 2, p.count - 1)]
            path.addCurve(to: p2,
                          control1: CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6),
                          control2: CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6))
        }
        return path
    }

    /// How far behind the clock the right edge runs: more than a sample's spacing plus jitter, so the newest sample is already there.
    private static let lag: TimeInterval = 1.5

    private var start: Date { (samples.last?.time ?? Date()).addingTimeInterval(-Double(TrafficMonitor.window)) }

    /// The time under the pointer (the chart's own selection), and the sample nearest to it.
    @State private var pointer: Date?
    private var hovered: TrafficMonitor.Sample? {
        guard live, let pointer else { return nil }
        return samples.min { abs($0.time.timeIntervalSince(pointer)) < abs($1.time.timeIntervalSince(pointer)) }
    }
    /// What the legend shows: the sample under the pointer, else the latest.
    private var shown: TrafficMonitor.Sample? { hovered ?? samples.last }

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: Space.m) {
                // Drawn by hand, not with Charts: Charts animates (and so stops and starts) whenever its data changes, and the slide must
                // never pause. Every frame the window's edges follow the clock, so the whole chart moves left steadily, and each point's
                // height eases toward its new value on its own clock. The right edge runs `lag` behind, so the newest sample is already there.
                TimelineView(.animation(paused: !live)) { timeline in
                    ZStack {
                        Canvas { ctx, size in drawChart(&ctx, size, now: timeline.date) }
                        GeometryReader { geo in
                            if let h = hovered, live {
                                let x = Self.x(h.time, now: timeline.date, width: geo.size.width)
                                Rectangle().fill(Palette.inkSecondary.color.opacity(0.45)).frame(width: 1, height: geo.size.height)
                                    .position(x: x, y: geo.size.height / 2).allowsHitTesting(false)
                            }
                            Color.clear.contentShape(Rectangle())
                                .onContinuousHover { phase in
                                    switch phase {
                                    case .active(let at):
                                        let edge = Date().addingTimeInterval(-Self.lag)
                                        pointer = edge.addingTimeInterval(-Double(TrafficMonitor.window) * (1 - Double(at.x / max(geo.size.width, 1))))
                                    case .ended: pointer = nil
                                    }
                                }
                        }
                    }
                }
                .overlay(alignment: .topTrailing) {
                    Text(speedText(top)).font(TypeScale.secondary).monospacedDigit()
                        .foregroundStyle(Palette.inkSecondary.color).padding(.trailing, 2)
                        .contentTransition(.numericText()).animation(.easeOut(duration: 0.4), value: top)
                }
                .frame(height: height)
                .accessibilityLabel("Speed over the last minute")
                .accessibilityValue(live ? "Download \(speedText(samples.last?.down ?? 0)), upload \(speedText(samples.last?.up ?? 0))" : "Not connected")
                .animation(nil, value: pointer)
                HStack(spacing: Space.xl) {
                    legend("arrow.down.circle", live ? speedText(shown?.down ?? 0) : "—", Palette.success.color)
                    legend("arrow.up.circle", live ? speedText(shown?.up ?? 0) : "—", Palette.warning.color)
                    Spacer()
                    Text(hovered.map { Self.clock.string(from: $0.time) } ?? "Last minute").font(TypeScale.secondary).foregroundStyle(Palette.inkSecondary.color)
                }
            }
            .padding(Space.l)
        }
        .opacity(live ? 1 : 0.45) // the whole panel, like the cards
        .animation(.easeOut(duration: 0.25), value: live)
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()

    private func legend(_ symbol: String, _ text: String, _ color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(text).font(TypeScale.bodyStrong).monospacedDigit().foregroundStyle(color)
                .contentTransition(.numericText()).animation(.easeOut(duration: 0.3), value: text)
        }
    }
}
