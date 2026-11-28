import SwiftUI

/// A one-line message under a row: what went wrong, or what to know.
public struct NoteLine: View {
    public enum Kind: Sendable { case error, warning }
    let kind: Kind
    let text: String
    public init(_ kind: Kind, _ text: String) { self.kind = kind; self.text = text }

    public var body: some View {
        let tone = kind == .error ? Palette.danger : Palette.warning
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: kind == .error ? "exclamationmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 11))
            Text(text).font(TypeScale.secondary).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(tone.color)
    }
}

/// A settings row: title and description on the left, the control on the right.
public struct FormRow<Control: View>: View {
    let title: String
    let detail: String?
    let error: String?
    let control: Control
    @Environment(\.searchQuery) private var query

    public init(_ title: String, detail: String? = nil, error: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title; self.detail = detail; self.error = error; self.control = control()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(alignment: .center, spacing: Space.l) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Highlight.attributed(title, query)).font(TypeScale.bodyStrong).foregroundStyle(Palette.ink.color)
                    if let detail, !detail.isEmpty {
                        Text(Highlight.attributed(detail, query)).font(TypeScale.secondary).foregroundStyle(Palette.inkSecondary.color)
                            .monospacedDigit().fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: Space.m)
                control
            }
            if let error { NoteLine(.error, error) }
        }
        .padding(.vertical, Space.m).padding(.horizontal, Space.l)
        .preference(key: RowTextsKey.self, value: ["\(title) \(detail ?? "")"])
    }
}

public extension FormRow where Control == EmptyView {
    init(_ title: String, detail: String? = nil, error: String? = nil) {
        self.init(title, detail: detail, error: error) { EmptyView() }
    }
}

/// A row that shows a value instead of a control.
public struct ValueRow: View {
    let title: String
    let value: String
    let detail: String?
    public init(_ title: String, _ value: String, detail: String? = nil) { self.title = title; self.value = value; self.detail = detail }
    public var body: some View {
        FormRow(title, detail: detail) {
            Text(value).font(TypeScale.body).monospacedDigit().foregroundStyle(Palette.inkSecondary.color)
                .textSelection(.enabled).multilineTextAlignment(.trailing)
        }
    }
}

/// The name of a group of rows on a page.
public struct SectionTitle: View {
    let text: String
    public init(_ text: String) { self.text = text }
    public var body: some View {
        Text(text).font(TypeScale.heading).foregroundStyle(Palette.ink.color)
            .padding(.top, Space.m).accessibilityAddTraits(.isHeader)
    }
}

/// How far a page has scrolled.
private struct ScrollOffsetKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// A page: header on top, content below, scrolling when it is long. Once it scrolls, a blue Liquid Glass bar floats at the
/// top with the title (and the page's controls) on it. An inner page passes `back` and gets a round back button left of
/// its title.
private struct PageViewportHeightKey: EnvironmentKey { static let defaultValue: CGFloat = 0 }

public extension EnvironmentValues {
    /// The height of the page's visible area (the window's content), for a page that wants to fill it.
    var pageViewportHeight: CGFloat {
        get { self[PageViewportHeightKey.self] }
        set { self[PageViewportHeightKey.self] = newValue }
    }
}

public struct PageScaffold<Trailing: View, Content: View, Footer: View>: View {
    let title: String
    let back: (() -> Void)?
    let trailing: Trailing
    let content: Content
    /// Pinned under the scrolling page (the buttons of an editor); empty for most pages.
    let footer: Footer
    @State private var scrolled = false
    public init(_ title: String, back: (() -> Void)? = nil, @ViewBuilder trailing: () -> Trailing, @ViewBuilder content: () -> Content,
                @ViewBuilder footer: () -> Footer) {
        self.title = title; self.back = back; self.trailing = trailing(); self.content = content(); self.footer = footer()
    }
    public var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                scaffold
                footer
            }
            .environment(\.pageViewportHeight, geo.size.height)
        }
    }

    private var scaffold: some View {
        ZStack(alignment: .top) {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.xl) {
                    PageHeader(title, back: back) { trailing }
                        .opacity(scrolled ? 0 : 1).allowsHitTesting(!scrolled) // the bar carries them now
                        .animation(.easeOut(duration: 0.18), value: scrolled)
                    // A section title sits close to its panel; the gap above it separates sections.
                    VStack(alignment: .leading, spacing: Space.s) { content }
                }
                .padding(Space.xl)
                .padding(.top, Space.m)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .background(GeometryReader { g in
                    Color.clear.preference(key: ScrollOffsetKey.self, value: -g.frame(in: .named("page")).minY)
                })
            }
            .coordinateSpace(name: "page")
            .onPreferenceChange(ScrollOffsetKey.self) { scrolled = $0 > 16 }
            .modifier(ScrollTracker { scrolled = $0 })
            .scrollIndicators(.never)
            FloatingBar(title, back: back, visible: scrolled) { trailing }
        }
    }
}

public extension PageScaffold where Footer == EmptyView {
    init(_ title: String, back: (() -> Void)? = nil, @ViewBuilder trailing: () -> Trailing, @ViewBuilder content: () -> Content) {
        self.init(title, back: back, trailing: trailing, content: content, footer: { EmptyView() })
    }
}

/// A destination chip: a dot in the destination's color, then its name.
public struct DestinationLabel: View {
    let name: String
    let color: Color
    public init(_ name: String, color: Color) { self.name = name; self.color = color }
    public var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(name).font(TypeScale.bodyStrong).lineLimit(1)
        }
        .foregroundStyle(Palette.ink.color)
    }
}
