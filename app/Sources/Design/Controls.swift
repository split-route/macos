import SwiftUI

// MARK: Buttons

public struct SolidButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(TypeScale.bodyStrong)
            .foregroundStyle(Color.white)
            .padding(.horizontal, 18).padding(.vertical, 11)
            .background(AccentSurface(RoundedRectangle(cornerRadius: Radius.row + 4, style: .continuous)).opacity(configuration.isPressed ? 0.8 : 1))
    }
}

public struct OutlineButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(TypeScale.bodyStrong)
            .foregroundStyle(Palette.ink.color)
            .padding(.horizontal, 16).padding(.vertical, 9)
            .background(Glass.control.opacity(configuration.isPressed ? 0.6 : 1), in: RoundedRectangle(cornerRadius: Radius.row + 2, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.row + 2, style: .continuous).stroke(Glass.stroke, lineWidth: 1))
    }
}

/// A small round glass button's look (the "..." menu, update, info).
public struct RoundGlass: ViewModifier {
    let size: CGFloat
    public init(size: CGFloat = 30) { self.size = size }
    public func body(content: Content) -> some View {
        content.frame(width: size, height: size).background(Circle().fill(Glass.control)).contentShape(Circle())
    }
}

extension View {
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
            .clipShape(RoundedRectangle(cornerRadius: Radius.panel + 4))
            .overlay(RoundedRectangle(cornerRadius: Radius.panel + 4).stroke(Glass.stroke, lineWidth: 1))
    }
}

public struct PageHeader<Trailing: View>: View {
    let title: String
    let summary: String
    let trailing: Trailing
    public init(_ title: String, summary: String, @ViewBuilder trailing: () -> Trailing) {
        self.title = title; self.summary = summary; self.trailing = trailing()
    }
    public var body: some View {
        HStack(alignment: .top, spacing: Space.l) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(TypeScale.title).foregroundStyle(Palette.ink.color)
                Text(summary).font(TypeScale.body).foregroundStyle(Palette.inkSecondary.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Space.l)
            trailing
        }
    }
}

/// An empty page is an invitation to act.
public struct EmptyState: View {
    let title: String
    let message: String
    let action: String
    let perform: () -> Void
    public init(title: String, message: String, action: String, perform: @escaping () -> Void = {}) {
        self.title = title; self.message = message; self.action = action; self.perform = perform
    }
    public var body: some View {
        VStack(spacing: Space.m) {
            Text(title).font(TypeScale.heading).foregroundStyle(Palette.ink.color)
            Text(message).font(TypeScale.body).foregroundStyle(Palette.inkSecondary.color)
                .multilineTextAlignment(.center).frame(maxWidth: 360)
            Button(action, action: perform).buttonStyle(SolidButtonStyle()).padding(.top, Space.xs)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 56)
    }
}
