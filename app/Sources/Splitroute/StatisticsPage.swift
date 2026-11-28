import Charts
import Design
import SwiftUI

/// The line under "Connected": how long the connection has been up, and the server (30:02 - Server name), ticking each second.
/// Anything else (not connected, connecting) shows `fallback`.
struct ConnectionLine: View {
    @EnvironmentObject private var model: AppModel
    let fallback: String

    var body: some View {
        if model.health == .active, let since = model.connectedSince, let name = model.selectedTunnel?.name {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Text("\(StatsData.uptime(ctx.date.timeIntervalSince(since))) - \(name)")
            }
        } else {
            Text(fallback)
        }
    }
}

/// Statistics: what the engine carried, direct and through a server, for a range (this connection, today, the last week, month
/// or three months). It is recorded by the app while it runs (`AppModel+Stats.swift`).
struct StatisticsPage: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("statsRange") private var rangeName = StatsRange.today.rawValue
    @AppStorage(Prefs.recordStats) private var record = true
    @State private var rows: [TrafficBucket] = []
    @State private var confirmingReset = false
    /// The time under the pointer on each chart: a chart shows its tooltip only for its own pointer.
    @State private var trafficHover: Date?
    @State private var speedHover: Date?

    /// The Connection range only exists while connected; without a connection the page shows today (and goes back to the
    /// chosen range when it connects again).
    private var connected: Bool { model.vpnOn && model.connectedSince != nil }
    private var range: StatsRange {
        let r = StatsRange(rawValue: rangeName) ?? .today
        return r == .connection && !connected ? .today : r
    }
    private var ranges: [StatsRange] { connected ? StatsRange.allCases : StatsRange.allCases.filter { $0 != .connection } }

    var body: some View {
        PageScaffold("Statistics") {
            EmptyView()
        } content: {
            recordPanel
            // The Connection tab carries the connection's uptime in brackets, ticking each second.
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                SheetTabs(options: ranges, selection: Binding(get: { range }, set: { rangeName = $0.rawValue }),
                          title: { r in
                              guard r == .connection, let since = model.connectedSince else { return r.rawValue }
                              return "\(r.rawValue) (\(StatsData.uptime(ctx.date.timeIntervalSince(since))))"
                          })
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, Space.s)
            cards
            if rows.isEmpty {
                Text(record ? "Nothing recorded in this range yet." : "Recording is off. Turn it on to count the traffic.")
                    .font(TypeScale.body).foregroundStyle(Palette.inkSecondary.color)
                    .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, Space.xl)
            } else {
                chart()
            }
            if !rows.isEmpty { speedChart() }
        }
        .task(id: rangeName) {
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
        .onChange(of: model.statsRevision) { _, _ in Task { await load() } }
        .onChange(of: connected) { _, _ in Task { await load() } }
        .confirmationDialog("Delete all statistics?", isPresented: $confirmingReset) {
            Button("Delete", role: .destructive) { model.resetStats() }
        } message: {
            Text("The recorded traffic is deleted. Counting goes on if recording is on.")
        }
    }

    // MARK: Recording

    private var recordPanel: some View {
        Panel {
            FormRow("Record statistics", detail: "Kept on this Mac and nothing is sent anywhere. Turning it on or off restarts the connection once.",
                    error: model.error("recordStats")) {
                settingsSwitch("Record statistics", isOn: Binding(get: { record }, set: { on in Task { await model.setRecordStats(on) } }))
            }
            Hairline()
            FormRow("Reset data", detail: "Delete everything recorded.") {
                Button("Reset…") { confirmingReset = true }.buttonStyle(OutlineButtonStyle())
            }
        }
    }

    // MARK: Cards

    private var totals: TrafficTotals { StatsData.totals(rows) }

    private var cards: some View {
        HStack(alignment: .top, spacing: Space.m) {
            card("Download", Self.bytes(totals.down), ["Proxy: \(Self.bytes(totals.proxyDown))", "Direct: \(Self.bytes(totals.directDown))"],
                 symbol: "arrow.down.circle", tint: Palette.success.color)
            card("Upload", Self.bytes(totals.up), ["Proxy: \(Self.bytes(totals.proxyUp))", "Direct: \(Self.bytes(totals.directUp))"],
                 symbol: "arrow.up.circle", tint: Palette.warning.color)
            card("Peak speed", Self.speed(max(totals.peakDown, totals.peakUp)), ["Down: \(Self.speed(totals.peakDown))", "Up: \(Self.speed(totals.peakUp))"],
                 symbol: "speedometer", tint: Accent.color)
        }
        .fixedSize(horizontal: false, vertical: true) // the cards are as tall as the tallest
    }

    /// A card with two lines under its figure, so every card is the same height.
    private func card(_ title: String, _ value: String, _ lines: [String], symbol: String, tint: Color) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: Space.s) {
                HStack(spacing: 6) {
                    Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(tint).accessibilityHidden(true)
                    Text(title).font(TypeScale.secondary).foregroundStyle(Palette.inkSecondary.color)
                }
                Text(value).font(TypeScale.title).monospacedDigit().foregroundStyle(Palette.ink.color).lineLimit(1).minimumScaleFactor(0.7)
                    .contentTransition(.numericText()).animation(.easeOut(duration: 0.4), value: value) // the digits roll to the new figure
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(lines, id: \.self) { Text($0).lineLimit(1).minimumScaleFactor(0.8).contentTransition(.numericText()).animation(.easeOut(duration: 0.4), value: $0) }
                }
                .font(TypeScale.secondary).monospacedDigit().foregroundStyle(Palette.inkSecondary.color)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(Space.l)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    // MARK: Charts

    private var granularity: StatsGranularity {
        let start = StatsData.start(of: range, now: Date(), connectedSince: model.connectedSince) ?? Date()
        return StatsData.granularity(of: range, start: start, now: Date())
    }

    /// Download and upload together, each column split into what a server carried and what went direct.
    private func chart() -> some View {
        let g = granularity
        let now = Date()
        let start = StatsData.start(of: range, now: now, connectedSince: model.connectedSince) ?? now
        let domain = StatsData.domain(of: range, start: start, now: now, granularity: g)
        let points = StatsData.points(rows, by: g)
        let slot = g.seconds
        let hovered = trafficHover.flatMap { h in points.first { h >= $0.date && h < $0.date.addingTimeInterval(slot) } }
        return Panel {
            VStack(alignment: .leading, spacing: Space.l) {
                HStack(alignment: .center, spacing: Space.m) {
                    Text("Traffic").font(TypeScale.bodyStrong).foregroundStyle(Palette.ink.color)
                    Spacer(minLength: Space.m)
                    legendItem("Server", Accent.color)
                    legendItem("Direct", Self.directColor)
                }
                Chart {
                    // Each column: the bigger of server and direct from the bottom, the smaller drawn over it, also from the bottom.
                    ForEach(points) { p in bars(p, slot: slot) }
                }
                .animation(.easeInOut(duration: 0.45), value: points) // bars and lines move to the new figures
                .animation(.easeInOut(duration: 0.45), value: domain)
                .chartXSelection(value: $trafficHover)
                .chartOverlay { proxy in hoverOverlay(proxy, hovered: hovered, at: { $0.date.addingTimeInterval(slot / 2) }) { tooltip($0, slot: slot, g) } }
                .chartForegroundStyleScale(["Server": Accent.color, "Direct": Self.directColor])
                .chartXScale(domain: domain)
                .chartXAxis { xAxis(g) }
                .chartLegend(.hidden) // drawn beside the title instead
                .chartYAxis { AxisMarks { v in AxisGridLine(); AxisValueLabel { if let n = v.as(Int.self) { Text(Self.bytes(n)) } } } }
                .padding(.top, Space.s)
                .frame(height: 220)
                .accessibilityLabel("Traffic by \(g == .day ? "day" : "half hour or hour")")
            }
            .padding(Space.l)
        }
    }

    /// The guide line and the tooltip, drawn inside the chart's own frame (an annotation above the plot is cut off by the panel). The
    /// tooltip sits at the top of the plot beside the line, on the side with room.
    private func hoverOverlay<Tip: View>(_ proxy: ChartProxy, hovered: TrafficPoint?, at time: @escaping (TrafficPoint) -> Date, @ViewBuilder tip: @escaping (TrafficPoint) -> Tip) -> some View {
        GeometryReader { geo in
            if let p = hovered, let x = proxy.position(forX: time(p)), let plot = proxy.plotFrame {
                let frame = geo[plot]
                let line = frame.minX + x
                let width: CGFloat = 230
                let right = line + 12 + width <= frame.maxX
                Rectangle().fill(Palette.inkSecondary.color.opacity(0.4)).frame(width: 1, height: frame.height)
                    .position(x: line, y: frame.midY).allowsHitTesting(false)
                tip(p)
                    .frame(width: width, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .offset(x: right ? line + 12 : line - 12 - width, y: frame.minY + 4)
                    .allowsHitTesting(false)
            }
        }
    }

    /// The average speed over the range (Home has the live one): a line each for download and upload, the average of the time
    /// recorded in each column. The peak is in the tooltip and the Peak speed card.
    private func speedChart() -> some View {
        let g = granularity
        let now = Date()
        let start = StatsData.start(of: range, now: now, connectedSince: model.connectedSince) ?? now
        let domain = StatsData.domain(of: range, start: start, now: now, granularity: g)
        let points = StatsData.points(rows, by: g)
        let slot = g.seconds
        let top = TrafficMonitor.niceTop(Double(points.map { max($0.peakDown, $0.peakUp) }.max() ?? 0))
        // The dots and lines sit at a slot's start (a day's middle), so the pointer picks the nearest of them, not the slot it is in.
        let hovered = speedHover.flatMap { h in points.min { abs(speedX($0, slot, g).timeIntervalSince(h)) < abs(speedX($1, slot, g).timeIntervalSince(h)) } }
        return Panel {
            VStack(alignment: .leading, spacing: Space.l) {
                HStack(alignment: .center, spacing: Space.m) {
                    Text("Speed").font(TypeScale.bodyStrong).foregroundStyle(Palette.ink.color)
                    Text("dots: average, lines: peak").font(TypeScale.secondary).foregroundStyle(Palette.inkSecondary.color)
                    Spacer(minLength: Space.m)
                    legendItem("Download", Palette.success.color)
                    legendItem("Upload", Palette.warning.color)
                }
                Chart {
                    ForEach(points) { p in speedMarks(p, slot: slot, g, alone: points.count < 3) }
                    // A slot's average holds across the slot, so the lines run from its start; the last one is carried to its end,
                    // and the chart is full width instead of starting and stopping half a slot in.
                    if g != .day, let last = points.last {
                        speedMark(last, slot, "Download", Double(last.peakDown), at: last.date.addingTimeInterval(slot))
                        speedMark(last, slot, "Upload", Double(last.peakUp), at: last.date.addingTimeInterval(slot))
                        speedArea("Download", Double(last.peakDown), at: last.date.addingTimeInterval(slot))
                        speedArea("Upload", Double(last.peakUp), at: last.date.addingTimeInterval(slot))
                    }
                }
                .animation(.easeInOut(duration: 0.45), value: points)
                .animation(.easeInOut(duration: 0.45), value: domain)
                .chartXSelection(value: $speedHover)
                .chartOverlay { proxy in hoverOverlay(proxy, hovered: hovered, at: { speedX($0, slot, g) }) { speedTooltip($0, slot: slot, g) } }
                .chartForegroundStyleScale(["Download": Palette.success.color, "Upload": Palette.warning.color])
                .chartXScale(domain: domain)
                .chartXAxis { xAxis(g) }
                .chartLegend(.hidden)
                // The lines are the peaks, far above the averages: a square-root scale keeps the dots off the floor. The grid is
                // evenly spaced on it (0, a ninth, four ninths, all of the top).
                .chartYScale(domain: 0...top, type: .squareRoot)
                .chartYAxis {
                    AxisMarks(values: [0, top / 9, top * 4 / 9, top]) { v in
                        AxisGridLine()
                        AxisValueLabel { if let n = v.as(Double.self) { Text(speedText(n)) } }
                    }
                }
                .padding(.top, Space.s)
                .frame(height: 180)
                .accessibilityLabel("Speed: average as dots, peak as lines")
            }
            .padding(Space.l)
        }
    }

    /// Where a slot's dots and line vertex are: its start, or the middle of a day.
    private func speedX(_ p: TrafficPoint, _ slot: TimeInterval, _ g: StatsGranularity) -> Date {
        g == .day ? p.date.addingTimeInterval(slot / 2) : p.date
    }

    /// The peak of each direction as a line with a wash under it, and the average as a dot on it, for every slot. A slot's peak holds
    /// across the slot, so the lines start at its start; a day is a point at its middle. With fewer than three points there is no
    /// line to see, so the peaks get a small diamond.
    @ChartContentBuilder private func speedMarks(_ p: TrafficPoint, slot: TimeInterval, _ g: StatsGranularity, alone: Bool) -> some ChartContent {
        let at = g == .day ? p.date.addingTimeInterval(slot / 2) : p.date
        speedMark(p, slot, "Download", Double(p.peakDown), at: at)
        speedMark(p, slot, "Upload", Double(p.peakUp), at: at)
        speedArea("Download", Double(p.peakDown), at: at)
        speedArea("Upload", Double(p.peakUp), at: at)
        speedDot("Download", p.avgDown, at: at, diamond: false)
        speedDot("Upload", p.avgUp, at: at, diamond: false)
        if alone {
            speedDot("Download", Double(p.peakDown), at: at, diamond: true)
            speedDot("Upload", Double(p.peakUp), at: at, diamond: true)
        }
    }

    /// The wash under a line, fading to nothing, like Home's chart: the speed reads as a shape and not only a stroke.
    private func speedArea(_ series: String, _ v: Double, at time: Date) -> some ChartContent {
        let color = series == "Download" ? Palette.success.color : Palette.warning.color
        let top = series == "Download" ? 0.42 : 0.32
        return AreaMark(x: .value("Time", time), yStart: .value("Bytes a second from", 0.0), yEnd: .value("Bytes a second", v), series: .value("Direction", "\(series) area"))
            .interpolationMethod(.monotone)
            .foregroundStyle(LinearGradient(colors: [color.opacity(top), color.opacity(0.03)], startPoint: .top, endPoint: .bottom))
    }

    private func speedDot(_ series: String, _ v: Double, at time: Date, diamond: Bool) -> some ChartContent {
        PointMark(x: .value("Time", time), y: .value("Bytes a second", v)).symbolSize(diamond ? 36 : 56)
            .symbol(diamond ? .diamond : .circle).foregroundStyle(by: .value("Direction", series))
    }

    private func speedMark(_ p: TrafficPoint, _ slot: TimeInterval, _ series: String, _ v: Double, at time: Date) -> some ChartContent {
        let x = PlottableValue.value("Time", time)
        return LineMark(x: x, y: .value("Bytes a second", v), series: .value("Direction", series))
            .foregroundStyle(by: .value("Direction", series)).interpolationMethod(.monotone)
    }

    private func speedTooltip(_ p: TrafficPoint, slot: TimeInterval, _ g: StatsGranularity) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(Self.when(p, slot: slot, g)).font(TypeScale.secondary.weight(.semibold)).foregroundStyle(Palette.ink.color)
            Text("Download: \(speedText(p.avgDown)) avg").foregroundStyle(Palette.inkSecondary.color)
            Text("Peak: \(speedText(Double(p.peakDown)))").padding(.bottom, Space.s)
            Text("Upload: \(speedText(p.avgUp)) avg")
            Text("Peak: \(speedText(Double(p.peakUp)))")
        }
        .font(TypeScale.secondary).monospacedDigit().foregroundStyle(Palette.inkSecondary.color)
        .padding(.horizontal, Space.m).padding(.vertical, Space.s)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.row, style: .continuous).stroke(Glass.stroke, lineWidth: 1))
    }

    /// A day by its date; a slot of time by its date and both ends: Nov 28, 15:00 - 15:30.
    private static func when(_ p: TrafficPoint, slot: TimeInterval, _ g: StatsGranularity) -> String {
        if g == .day { return p.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) }
        let time = Date.FormatStyle().hour().minute()
        return "\(p.date.formatted(.dateTime.month(.abbreviated).day())), \(p.date.formatted(time)) - \(p.date.addingTimeInterval(slot).formatted(time))"
    }

    /// A column's bars: each fills its slot with a little room either side (the tooltip's line is the middle of the slot), the bigger
    /// of server and direct behind and the smaller drawn over it, both from the bottom.
    @ChartContentBuilder private func bars(_ p: TrafficPoint, slot: TimeInterval) -> some ChartContent {
        ForEach(Array(StatsData.segments(p).enumerated()), id: \.offset) { _, s in
            bar(p, slot, s)
        }
    }

    private func bar(_ p: TrafficPoint, _ slot: TimeInterval, _ s: (route: String, from: Int, to: Int)) -> some ChartContent {
        let start: Date = p.date.addingTimeInterval(slot * 0.08)
        let end: Date = p.date.addingTimeInterval(slot * 0.92)
        let x0 = PlottableValue.value("Slot start", start), x1 = PlottableValue.value("Slot end", end)
        let y0 = PlottableValue.value("Bytes from", s.from), y1 = PlottableValue.value("Bytes to", s.to)
        return RectangleMark(xStart: x0, xEnd: x1, yStart: y0, yEnd: y1).cornerRadius(2).foregroundStyle(by: .value("Route", s.route))
    }

    /// What a bar says when the pointer is over it: when, and the exact proxy and direct bytes.
    private func tooltip(_ p: TrafficPoint, slot: TimeInterval, _ g: StatsGranularity) -> some View {
        let when = Self.when(p, slot: slot, g)
        return VStack(alignment: .leading, spacing: 2) {
            Text(when).font(TypeScale.secondary.weight(.semibold)).foregroundStyle(Palette.ink.color)
            Text("Download: \(Self.bytes(p.directDown + p.proxyDown))")
            Text("Upload: \(Self.bytes(p.directUp + p.proxyUp))")
            Text("Direct: ↓\(Self.bytes(p.directDown)) / ↑\(Self.bytes(p.directUp))").padding(.top, Space.s)
            Text("Proxy: ↓\(Self.bytes(p.proxyDown)) / ↑\(Self.bytes(p.proxyUp))")
        }
        .font(TypeScale.secondary).monospacedDigit().foregroundStyle(Palette.inkSecondary.color)
        .padding(.horizontal, Space.m).padding(.vertical, Space.s)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.row, style: .continuous).stroke(Glass.stroke, lineWidth: 1))
    }

    /// A solid gray (no opacity, so it is the same over the blue bar behind it as over nothing).
    private static var directColor: Color { Tone(light: 0x9CA3AF, dark: 0x6B7280).color }

    private func legendItem(_ name: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(name).font(TypeScale.secondary).foregroundStyle(Palette.inkSecondary.color)
        }
        .accessibilityElement(children: .combine)
    }

    /// The labels along the time axis: hours for a day, minutes for a young connection, weekdays for a week, dates beyond.
    @AxisContentBuilder private func xAxis(_ g: StatsGranularity) -> some AxisContent {
        switch (g, range) {
        case (.fiveMinutes, _): AxisMarks(values: .stride(by: .minute, count: 30)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.hour().minute()) }
        case (.halfHour, _), (.hour, .today): AxisMarks(values: .stride(by: .hour, count: 6)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.hour()) }
        case (.hour, _): AxisMarks(values: .stride(by: .hour, count: 2)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.hour()) }
        case (.day, .week): AxisMarks(values: .stride(by: .day)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.weekday(.abbreviated)) }
        case (.day, .month): AxisMarks(values: .stride(by: .day, count: 7)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.month(.abbreviated).day()) }
        default: AxisMarks(values: .stride(by: .day, count: 14)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.month(.abbreviated).day()) }
        }
    }

    // MARK: Data

    private func load() async {
        guard let store = model.store else { return }
        let now = Date()
        guard let start = StatsData.start(of: range, now: now, connectedSince: model.vpnOn ? model.connectedSince : nil) else {
            rows = []
            return
        }
        let from = Store.bucket(of: start)
        let found = await Task.detached(priority: .utility) { (try? store.traffic(from: from)) ?? [] }.value
        if found != rows { rows = found }
    }

    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .decimal
        f.allowedUnits = [.useKB, .useMB, .useGB, .useTB] // "0 KB", not "Zero KB"
        f.allowsNonnumericFormatting = false
        return f
    }()
    private static func bytes(_ n: Int) -> String { byteFormatter.string(fromByteCount: Int64(n)) }
    private static func speed(_ n: Int) -> String { n == 0 ? "—" : speedText(Double(n)) }
}
