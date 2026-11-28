import SwiftUI

private struct SearchQueryKey: EnvironmentKey { static let defaultValue = "" }

public extension EnvironmentValues {
    /// What the page is being searched for ("" when it isn't): rows mark it in their text.
    var searchQuery: String {
        get { self[SearchQueryKey.self] }
        set { self[SearchQueryKey.self] = newValue }
    }
}

public enum Highlight {
    private static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    public static func clean(_ query: String) -> String { query.trimmingCharacters(in: .whitespaces) }

    /// Whether `text` holds `query` (case and accents ignored). An empty query matches everything.
    public static func matches(_ text: String, _ query: String) -> Bool {
        let q = clean(query)
        return q.isEmpty || text.range(of: q, options: options) != nil
    }

    /// `text` with every occurrence of `query` marked, for `Text(...)`. Unchanged when the query is empty.
    public static func attributed(_ text: String, _ query: String) -> AttributedString {
        var out = AttributedString(text)
        let q = clean(query)
        guard !q.isEmpty else { return out }
        var from = text.startIndex
        while from < text.endIndex, let r = text.range(of: q, options: options, range: from..<text.endIndex) {
            if let lo = AttributedString.Index(r.lowerBound, within: out), let hi = AttributedString.Index(r.upperBound, within: out) {
                out[lo..<hi].backgroundColor = Accent.color.opacity(0.4)
            }
            from = r.upperBound
        }
        return out
    }
}

/// The text of every row inside a section, so the section can tell whether the search matches anything in it.
struct RowTextsKey: PreferenceKey {
    static var defaultValue: [String] = []
    static func reduce(value: inout [String], nextValue: () -> [String]) { value += nextValue() }
}

/// How many sections of a page the search leaves visible.
private struct ShownSectionsKey: PreferenceKey {
    static var defaultValue = 0
    static func reduce(value: inout Int, nextValue: () -> Int) { value += nextValue() }
}

/// A titled panel of settings that hides itself when the page is searched and nothing in it (its title, or the title and
/// detail of a row) matches. A section that matches shows all of its rows, the matching words marked.
public struct SettingsSection<Content: View>: View {
    let title: String
    let content: Content
    @Environment(\.searchQuery) private var query
    @State private var texts: [String] = []

    public init(_ title: String, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }

    private var shown: Bool { Highlight.matches(title, query) || texts.contains { Highlight.matches($0, query) } }

    public var body: some View {
        Group {
            if shown {
                VStack(alignment: .leading, spacing: Space.s) {
                    SectionTitle(title)
                    Panel { content }
                }
                .onPreferenceChange(RowTextsKey.self) { texts = $0 }
            }
        }
        // A button elsewhere can scroll to it (`pageScrollTarget`). The id covers 64 pt above the section (the padding is taken
        // back below, so nothing moves): scrolled to the top of the page, the title ends up clear of the floating bar.
        .padding(.top, 64).id(title).padding(.top, -64)
        .preference(key: ShownSectionsKey.self, value: shown ? 1 : 0)
    }
}

/// A settings page with a search button in its top bar. The query is passed down to the rows; with nothing left it says so.
public struct SettingsPage<Content: View>: View {
    let title: String
    let content: Content
    @State private var query = ""
    @State private var shown = 1

    public init(_ title: String, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }

    public var body: some View {
        PageScaffold(title) {
            ToolbarGroup { ToolbarSearch(text: $query, prompt: "Search settings…") }
        } content: {
            content
            if shown == 0 {
                Text("No settings match.").font(TypeScale.body).foregroundStyle(Palette.inkSecondary.color)
                    .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, Space.xl)
            }
        }
        .environment(\.searchQuery, query)
        .onPreferenceChange(ShownSectionsKey.self) { shown = $0 }
    }
}
