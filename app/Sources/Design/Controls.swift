import SwiftUI

// MARK: Buttons

public struct SolidButtonStyle: ButtonStyle {
    @Environment(\.isFocused) private var focused
    public init() {}
    @ViewBuilder
    public func makeBody(configuration: Configuration) -> some View {
        let label = configuration.label
            .font(TypeScale.bodyStrong)
            .foregroundStyle(Color.white)
            .padding(.horizontal, 18).padding(.vertical, 11)
        if #available(macOS 26, *) {
            label.glassEffect(.regular.tint(Accent.color).interactive(), in: Capsule())
                .overlay(Capsule().strokeBorder(Color.white.opacity(focused ? 0.9 : 0), lineWidth: 2)) // keyboard focus
        } else {
            label.background(AccentSurface(RoundedRectangle(cornerRadius: Radius.row + 2, style: .continuous)).opacity(configuration.isPressed ? 0.8 : 1))
                .overlay(RoundedRectangle(cornerRadius: Radius.row + 2, style: .continuous).strokeBorder(Color.white.opacity(focused ? 0.9 : 0), lineWidth: 2))
        }
    }
}

public struct OutlineButtonStyle: ButtonStyle {
    @Environment(\.isFocused) private var focused
    public init() {}
    @ViewBuilder
    public func makeBody(configuration: Configuration) -> some View {
        let label = configuration.label
            .font(TypeScale.bodyStrong)
            .foregroundStyle(Palette.ink.color)
            .padding(.horizontal, 16).padding(.vertical, 9)
        if #available(macOS 26, *) {
            label.glassEffect(.regular.interactive(), in: Capsule())
                .overlay(Capsule().strokeBorder(Accent.color.opacity(focused ? 0.9 : 0), lineWidth: 2)) // keyboard focus
        } else {
            label
                .background(Glass.control.opacity(configuration.isPressed ? 0.6 : 1), in: RoundedRectangle(cornerRadius: Radius.row + 2, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.row + 2, style: .continuous).stroke(focused ? Accent.color : Glass.stroke, lineWidth: focused ? 2 : 1))
        }
    }
}

/// A small round glass button's look (the "..." menu, update, info).
public struct RoundGlass: ViewModifier {
    let size: CGFloat
    public init(size: CGFloat = 30) { self.size = size }
    @ViewBuilder
    public func body(content: Content) -> some View {
        let sized = content.frame(width: size, height: size).contentShape(Circle())
        if #available(macOS 26, *) {
            sized.glassEffect(.regular.interactive(), in: Circle())
        } else {
            sized.background(Circle().fill(Glass.control))
        }
    }
}

/// The top bar's material: Liquid Glass on macOS 26+ (what a native toolbar uses), a plain glass fill before.
private struct ToolbarGlass<S: Shape>: ViewModifier {
    let shape: S
    var interactive = false
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            content.background(shape.fill(Glass.control)).overlay(shape.stroke(Glass.stroke, lineWidth: 1))
        }
    }
}

/// Puts a group of top-bar items in one glass container, so they blend and morph like a native toolbar's.
public struct ToolbarGroup<Content: View>: View {
    let content: Content
    public init(@ViewBuilder content: () -> Content) { self.content = content() }
    public var body: some View {
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: Space.s) { HStack(spacing: Space.s) { content } }
        } else {
            HStack(spacing: Space.s) { content }
        }
    }
}

/// A round "+" for a page's top bar.
public extension View {
    /// The glass of a round toolbar button (the search and add buttons'), for a control that isn't a plain button, such as a menu.
    func toolbarCircleGlass() -> some View { modifier(ToolbarGlass(shape: Circle(), interactive: true)) }
}

public struct ToolbarAddButton: View {
    let label: String
    let action: () -> Void
    public init(_ label: String, action: @escaping () -> Void) { self.label = label; self.action = action }
    public var body: some View {
        Button(action: action) {
            Image(systemName: "plus").font(.system(size: 15, weight: .medium)).foregroundStyle(Palette.ink.color)
                .frame(width: 38, height: 38).contentShape(Circle())
        }
        .buttonStyle(.plain)
        .modifier(ToolbarGlass(shape: Circle(), interactive: true))
        .keyboardShortcut("n", modifiers: .command)
        .help("\(label) (⌘N)").accessibilityLabel(label)
    }
}

/// A round search button that opens into a field in place; it folds back when it is empty and loses focus.
public struct ToolbarSearch: View {
    @Binding var text: String
    let prompt: String
    @State private var open = false
    @FocusState private var focused: Bool
    public init(text: Binding<String>, prompt: String) { self._text = text; self.prompt = prompt }

    private var expanded: Bool { open || !text.isEmpty }

    public var body: some View {
        Group {
            if expanded {
                // Icon and text share a baseline: Inter and the symbol font have different vertical centers, so centering
                // them leaves the text a point high.
                HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                    Image(systemName: "magnifyingglass").font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.inkSecondary.color)
                    TextField(prompt, text: $text).textFieldStyle(.plain).font(TypeScale.body).focused($focused)
                        .onExitCommand { text = ""; open = false }
                    if !text.isEmpty {
                        Button { text = ""; focused = true } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.inkSecondary.color) }
                            .buttonStyle(.plain).accessibilityLabel("Clear search")
                    }
                }
                .frame(maxHeight: .infinity, alignment: .center) // centered in the capsule, whatever the first layout gave the text
                .padding(.horizontal, 14).frame(width: 240, height: 38)
                .modifier(ToolbarGlass(shape: Capsule()))
                // Only a field the person opened takes the focus. The page header and the floating bar each hold a search, and both
                // expand when text is typed: the one that appears from that must not pull the focus (and select the text).
                .onAppear { if open { focused = true } }
                .onChange(of: focused) { _, f in if !f && text.isEmpty { open = false } }
                .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .trailing)))
            } else {
                Button { open = true } label: {
                    Image(systemName: "magnifyingglass").font(.system(size: 14, weight: .medium)).foregroundStyle(Palette.ink.color)
                        .frame(width: 38, height: 38).contentShape(Circle())
                }
                .buttonStyle(.plain)
                .modifier(ToolbarGlass(shape: Circle(), interactive: true))
                .help("Search (⌘K)").accessibilityLabel("Search")
                .transition(.opacity)
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: expanded)
        // ⌘K opens the field (and focuses it) from anywhere on the page.
        .background(Button("Search") { open = true; focused = true }.keyboardShortcut("k", modifiers: .command).opacity(0).allowsHitTesting(false).accessibilityHidden(true))
    }
}

extension View {
    /// A field or control surface in `shape`: Liquid Glass on macOS 26+, a soft fill and hairline before.
    @ViewBuilder
    public func glassSurface<S: Shape>(_ shape: S) -> some View {
        if #available(macOS 26, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(shape.fill(Glass.control)).overlay(shape.stroke(Glass.stroke, lineWidth: 1))
        }
    }

    /// A small label or badge on glass (Liquid Glass on macOS 26+, a soft fill before).
    @ViewBuilder
    public func glassCapsule() -> some View {
        if #available(macOS 26, *) {
            glassEffect(.regular, in: Capsule())
        } else {
            background(Capsule().fill(Glass.control))
        }
    }

    public func roundGlass(_ size: CGFloat = 30) -> some View { modifier(RoundGlass(size: size)) }
}

// MARK: The tunnel line

private struct LineStroke: Shape {
    var progress: Double
    var animatableData: Double { get { progress } set { progress = newValue } }
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.midY))
        p.addLine(to: CGPoint(x: r.minX + (r.width - 12) * progress, y: r.midY))
        return p
    }
}

/// A tunnel drawn as a line ending in a node: solid and filled when connected,
/// dashed and hollow when not. Connecting is the one animated moment: the line
/// draws toward the node.
public struct LineMark: View {
    let state: TunnelState
    let line: Line
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(state: TunnelState, line: Line) { self.state = state; self.line = line }

    private var progress: Double {
        switch state {
        case .connected, .ready: return 1
        case .connecting: return 0.6
        default: return 0
        }
    }

    public var body: some View {
        ZStack(alignment: .trailing) {
            GeometryReader { g in
                Path { p in
                    p.move(to: CGPoint(x: 0, y: g.size.height / 2))
                    p.addLine(to: CGPoint(x: g.size.width - 12, y: g.size.height / 2))
                }
                .stroke(line.color.opacity(0.45), style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [1, 6]))
                LineStroke(progress: progress)
                    .stroke(line.color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.7), value: progress)
            }
            Circle()
                .fill(state == .connected ? line.color : Palette.surface.color)
                .overlay(Circle().stroke(nodeStroke, lineWidth: 3))
                .frame(width: 12, height: 12)
        }
        .accessibilityHidden(true)
    }

    private var nodeStroke: Color {
        if case .failed = state { return Palette.danger.color }
        return line.color
    }
}

/// A tunnel's color and name, wherever a tunnel is referred to.
public struct TunnelChip: View {
    let name: String
    let line: Line
    public init(name: String, line: Line) { self.name = name; self.line = line }
    public var body: some View {
        HStack(spacing: 6) {
            Circle().fill(line.color).frame(width: 8, height: 8)
            Text(name).font(TypeScale.bodyStrong).lineLimit(1)
        }
        .foregroundStyle(Palette.ink.color)
    }
}

// MARK: Action choice

/// Direct, Block or Tunnel for one list. Keyboard: focus it, then left and
/// right arrows change the choice. VoiceOver sees one adjustable element.
public struct ActionChoice: View {
    let listName: String
    @Binding var selection: ListAction
    let tunnelLine: Line?
    let allowed: [ListAction]
    /// Shows the focus ring without real focus, for screenshots.
    var forceFocus = false
    @FocusState private var focused: Bool

    public init(listName: String, selection: Binding<ListAction>, tunnelLine: Line?,
                allowed: [ListAction] = ListAction.allCases, forceFocus: Bool = false) {
        self.listName = listName; self._selection = selection; self.tunnelLine = tunnelLine
        self.allowed = allowed; self.forceFocus = forceFocus
    }

    private func dot(_ a: ListAction) -> Color {
        switch a {
        case .direct: return Palette.ink.color
        case .block: return Palette.danger.color
        case .tunnel: return tunnelLine?.color ?? Palette.inkSecondary.color
        }
    }

    private func step(_ delta: Int) {
        guard let i = allowed.firstIndex(of: selection) else { return }
        selection = allowed[min(max(i + delta, 0), allowed.count - 1)]
    }

    public var body: some View {
        HStack(spacing: 2) {
            ForEach(allowed, id: \.self) { a in
                HStack(spacing: 6) {
                    Circle().fill(dot(a)).frame(width: 7, height: 7)
                        .opacity(selection == a ? 1 : 0.35)
                    Text(a.rawValue).font(selection == a ? TypeScale.bodyStrong : TypeScale.body).lineLimit(1).fixedSize()
                }
                .foregroundStyle(selection == a ? Palette.ink.color : Palette.inkSecondary.color)
                .padding(.horizontal, 11).padding(.vertical, 5)
                .background {
                    if selection == a {
                        RoundedRectangle(cornerRadius: Radius.control - 2)
                            .fill(Palette.surface.color)
                            .overlay(RoundedRectangle(cornerRadius: Radius.control - 2).stroke(Palette.hairline.color, lineWidth: 1))
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { selection = a }
            }
        }
        .padding(2)
        .background(Palette.ground.color, in: RoundedRectangle(cornerRadius: Radius.control))
        .overlay {
            if focused || forceFocus {
                RoundedRectangle(cornerRadius: Radius.control + 2).stroke(Palette.ink.color, lineWidth: 2).padding(-3)
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onMoveCommand { dir in
            switch dir {
            case .left: step(-1)
            case .right: step(1)
            default: break
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Action for \(listName)")
        .accessibilityValue(selection.rawValue)
        .accessibilityAdjustableAction { dir in step(dir == .increment ? 1 : -1) }
    }
}

// MARK: Structure

public struct Hairline: View {
    public init() {}
    public var body: some View { Glass.divider.frame(height: 1) }
}

/// One panel holds a page's rows; rules between rows mean "next item".
public struct Panel<Content: View>: View {
    let content: Content
    public init(@ViewBuilder _ content: () -> Content) { self.content = content() }
    public var body: some View {
        VStack(spacing: 0) { content }
            .background(Glass.fill)
            .clipShape(RoundedRectangle(cornerRadius: Radius.panel))
            .overlay(RoundedRectangle(cornerRadius: Radius.panel).stroke(Glass.stroke, lineWidth: 1))
    }
}

public struct PageHeader<Trailing: View>: View {
    let title: String
    let back: (() -> Void)?
    let trailing: Trailing
    public init(_ title: String, back: (() -> Void)? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title; self.back = back; self.trailing = trailing()
    }
    public var body: some View {
        HStack(alignment: .center, spacing: Space.l) {
            if let back { BackButton(action: back) }
            Text(title).font(TypeScale.title).foregroundStyle(Palette.ink.color)
            Spacer(minLength: Space.l)
            trailing
        }
    }
}

/// A round liquid button that leaves an inner page, left of its title.
public struct BackButton: View {
    let size: CGFloat
    let action: () -> Void
    public init(size: CGFloat = 38, action: @escaping () -> Void) { self.size = size; self.action = action }
    public var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.left").font(.system(size: size * 0.4, weight: .semibold)).foregroundStyle(Palette.ink.color)
                .frame(width: size, height: size).contentShape(Circle())
        }
        .buttonStyle(.plain)
        .modifier(ToolbarGlass(shape: Circle(), interactive: true))
        .keyboardShortcut("[", modifiers: .command)
        .help("Back (⌘[)").accessibilityLabel("Back")
    }
}

/// The bar that floats over a page's top once it scrolls: a round Liquid Glass box inset from the page's edges, like the
/// sidebar's panel, with the back button (inner pages), the title and the page's own controls in it. Content scrolls
/// underneath and shows through.
public struct FloatingBar<Trailing: View>: View {
    public static var height: CGFloat { 48 }
    let title: String
    let back: (() -> Void)?
    let visible: Bool
    let trailing: Trailing
    @Environment(\.colorScheme) private var scheme
    public init(_ title: String, back: (() -> Void)? = nil, visible: Bool = true, @ViewBuilder trailing: () -> Trailing) {
        self.title = title; self.back = back; self.visible = visible; self.trailing = trailing()
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        HStack(spacing: Space.l) {
            if let back { BackButton(size: 32, action: back) }
            Text(title).font(TypeScale.heading).foregroundStyle(Palette.ink.color).lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: Space.l)
            trailing.scaleEffect(0.84, anchor: .trailing)
        }
        .padding(.horizontal, Space.m)
        .frame(height: Self.height).frame(maxWidth: .infinity)
        .modifier(BarGlass(shape: shape, scheme: scheme))
        .padding(.horizontal, Space.l).padding(.top, Space.s)
        .opacity(visible ? 1 : 0)
        .offset(y: visible ? 0 : -8)
        .allowsHitTesting(visible)
        .animation(.easeOut(duration: 0.18), value: visible)
    }
}

/// The box's surface: Liquid Glass on macOS 26+ like the sidebar's panel, a material before; a hairline and a soft shadow.
private struct BarGlass: ViewModifier {
    let shape: RoundedRectangle
    let scheme: ColorScheme
    func body(content: Content) -> some View {
        Group {
            if #available(macOS 26, *) {
                content.glassEffect(.regular.tint(scheme == .dark ? Color.black.opacity(0.18) : nil), in: shape)
            } else {
                content.background(.regularMaterial, in: shape)
            }
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(Glass.stroke, lineWidth: 0.5))
        .shadow(color: .black.opacity(scheme == .dark ? 0.30 : 0.10), radius: 7, y: 2)
    }
}

/// Reports a ScrollView's offset: past a few points it is "scrolled" and the page's floating bar shows.
public struct ScrollTracker: ViewModifier {
    let report: (Bool) -> Void
    public init(report: @escaping (Bool) -> Void) { self.report = report }
    public func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y > 16 } action: { _, now in report(now) }
        } else {
            content
        }
    }
}

/// An empty page is an invitation to act: a glass symbol, what this is for, one button.
public struct EmptyState: View {
    let symbol: String
    let title: String
    let message: String
    let action: String
    let perform: () -> Void
    public init(symbol: String = "tray", title: String, message: String, action: String, perform: @escaping () -> Void = {}) {
        self.symbol = symbol; self.title = title; self.message = message; self.action = action; self.perform = perform
    }
    public var body: some View {
        VStack(spacing: Space.m) {
            Image(systemName: symbol).font(.system(size: 30, weight: .light)).foregroundStyle(Accent.color)
                .frame(width: 76, height: 76).glassSurface(Circle())
                .shadow(color: Accent.glow.opacity(0.5), radius: 14)
                .padding(.bottom, Space.xs).accessibilityHidden(true)
            Text(title).font(TypeScale.title).foregroundStyle(Palette.ink.color)
            Text(message).font(TypeScale.body).foregroundStyle(Palette.inkSecondary.color)
                .multilineTextAlignment(.center).frame(maxWidth: 380)
            Button(action, action: perform).buttonStyle(SolidButtonStyle()).padding(.top, Space.s)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 56)
    }
}

/// A time as a pill whose colour says how good it is: under 150 ms green, under 400 ms amber, slower red.
public struct LatencyPill: View {
    let ms: Int
    public init(ms: Int) { self.ms = ms }
    private var tone: Color { ms < 250 ? Palette.success.color : (ms < 400 ? Palette.warning.color : Palette.danger.color) }
    public var body: some View {
        Text("\(ms) ms").font(TypeScale.secondary.weight(.semibold)).monospacedDigit().foregroundStyle(tone)
            .padding(.horizontal, 9).padding(.vertical, 3)
            .background(Capsule().fill(tone.opacity(0.14)))
            .overlay(Capsule().strokeBorder(tone.opacity(0.28), lineWidth: 0.75))
    }
}

/// The same pill for a test that failed ("Timeout"): red, with the reason.
public struct FailurePill: View {
    let text: String
    public init(_ text: String) { self.text = text }
    public var body: some View {
        Text(text).font(TypeScale.secondary.weight(.semibold)).foregroundStyle(Palette.danger.color)
            .padding(.horizontal, 9).padding(.vertical, 3)
            .background(Capsule().fill(Palette.danger.color.opacity(0.14)))
            .overlay(Capsule().strokeBorder(Palette.danger.color.opacity(0.28), lineWidth: 0.75))
    }
}

/// A switch that shows work in progress: a small spinner beside it, and no second tap, until the change has been applied.
public struct PendingToggle: View {
    let title: String
    @Binding var isOn: Bool
    let pending: Bool
    public init(_ title: String, isOn: Binding<Bool>, pending: Bool) { self.title = title; self._isOn = isOn; self.pending = pending }
    public var body: some View {
        HStack(spacing: Space.s) {
            if pending { ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 14, height: 14).transition(.opacity) }
            Toggle(title, isOn: $isOn).labelsHidden().toggleStyle(.switch).controlSize(.small).tint(Accent.color)
                .allowsHitTesting(!pending)
        }
        .animation(.easeOut(duration: 0.15), value: pending)
        .accessibilityElement(children: .contain)
        .accessibilityValue(pending ? "Working" : "")
    }
}
