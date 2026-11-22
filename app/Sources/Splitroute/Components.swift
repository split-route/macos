import AppKit
import SwiftUI

/// The row on every settings page: a title with a gray description on the left,
/// the control on the right, the daemon's error under both. The settings look
/// is set here, so pages don't style rows themselves.
struct SettingRow<Control: View>: View {
    let title: String
    var description: String?
    var error: String?
    let control: Control

    init(_ title: String, description: String? = nil, error: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.description = description
        self.error = error
        self.control = control()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    if let description, !description.isEmpty {
                        Text(description)
                            .font(.subheadline)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 12)
                control
            }
            if let error { ErrorText(error) }
        }
        .padding(.vertical, 4)
    }
}

extension SettingRow where Control == EmptyView {
    init(_ title: String, description: String? = nil, error: String? = nil) {
        self.init(title, description: description, error: error) { EmptyView() }
    }
}

/// A row that shows a value instead of a control (status pages).
struct ValueRow: View {
    let title: String
    let value: String
    var description: String?
    /// SF Mono for technical values (addresses); numbers always get tabular digits.
    var mono = false

    init(_ title: String, _ value: String, description: String? = nil, mono: Bool = false) {
        self.title = title
        self.value = value
        self.description = description
        self.mono = mono
    }

    var body: some View {
        SettingRow(title, description: description) {
            Text(value)
                .fontDesign(mono ? .monospaced : .default)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .multilineTextAlignment(.trailing)
        }
    }
}

struct ErrorText: View {
    let message: String
    init(_ message: String) { self.message = message }

    var body: some View {
        Label(message, systemImage: "exclamationmark.circle.fill")
            .font(.subheadline)
            .foregroundStyle(.red)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct WarningText: View {
    let message: String
    init(_ message: String) { self.message = message }

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.subheadline)
            .foregroundStyle(.orange)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
}

extension Color {
    /// Near-black page background in dark mode, like Raycast; the system color in light mode.
    static let pageBackground = Color(nsColor: NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 0.08, alpha: 1) : .windowBackgroundColor
    })
}

/// An SF Symbol on a colored rounded square, like System Settings' sidebar.
/// The only place with hard-coded colors.
struct IconTile: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 20

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.55, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous).fill(color.gradient))
    }
}

/// Direct / Block / Tunnel, applied as soon as it changes. For Tunnel a second
/// menu picks which one: the default tunnel (the first connected) or a named one.
struct ActionPicker: View {
    let action: Action
    var tunnel: String?
    var tunnels: [String] = []
    let set: (Action, String?) -> Void

    var body: some View {
        HStack(spacing: 6) {
            SelectMenu(title: action.label, options: Action.allCases, label: \.label, selected: action) {
                if $0 != action { set($0, nil) }
            }
            if action == .tunnel, !tunnels.isEmpty || tunnel != nil {
                // "" is the default tunnel. A named tunnel is always an option, even if it's missing from the list.
                let options = [""] + (tunnel.map { n in tunnels.contains(n) ? tunnels : tunnels + [n] } ?? tunnels)
                SelectMenu(title: tunnel ?? "Default tunnel", options: options,
                           label: { $0.isEmpty ? "Default tunnel" : $0 }, selected: tunnel ?? "") {
                    set(.tunnel, $0.isEmpty ? nil : $0)
                }
            }
        }
    }
}

/// A Raycast-style select: the value and a chevron as plain text, no bezel,
/// opening a popover. Lists longer than 8 get a search field.
struct SelectMenu<Value: Hashable>: View {
    let title: String
    let options: [Value]
    let label: (Value) -> String
    var selected: Value?
    let onSelect: (Value) -> Void

    @State private var open = false
    @State private var query = ""
    @State private var highlighted: Int? // index into matches, moved by arrow keys and the pointer
    @State private var keyMonitor: Any?
    private var searchable: Bool { options.count > 8 }

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 6) {
                Text(title)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(open ? 180 : 0))
                    .animation(.easeOut(duration: 0.15), value: open)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(open ? 0.1 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $open, arrowEdge: .bottom) { list }
    }

    private var matches: [Value] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? options : options.filter { label($0).localizedCaseInsensitiveContains(q) }
    }

    private func pick(_ v: Value) {
        open = false
        query = ""
        onSelect(v)
    }

    private var rows: some View {
        VStack(spacing: 2) {
            if matches.isEmpty {
                Text("No matches").foregroundStyle(.secondary).padding(12)
            }
            ForEach(Array(matches.enumerated()), id: \.element) { i, v in
                MenuRow(text: label(v), checked: v == selected, highlighted: highlighted == i,
                        hover: { if $0 { highlighted = i } }) { pick(v) }
                    .id(v)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 12)
    }

    /// Up/Down move the highlight, Return picks it. A local monitor works on
    /// macOS 13 (onKeyPress is 14+) and sees keys even while the search field
    /// has focus; only these keys are taken, the rest go to the field.
    private func installKeys() {
        highlighted = matches.firstIndex { $0 == selected } ?? 0
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            let n = matches.count
            switch e.keyCode {
            case 125: // down
                if n > 0 { highlighted = min((highlighted ?? -1) + 1, n - 1) }
            case 126: // up
                if n > 0 { highlighted = max((highlighted ?? n) - 1, 0) }
            case 36, 76: // return, enter
                if let i = highlighted, i < n { pick(matches[i]) }
            default:
                return e
            }
            return nil
        }
    }

    private func removeKeys() {
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        keyMonitor = nil
    }

    @ViewBuilder private var list: some View {
        if searchable {
            VStack(spacing: 0) {
                TextField("Search…", text: $query)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .onChange(of: query) { _ in highlighted = matches.isEmpty ? nil : 0 }
                Divider()
                ScrollViewReader { proxy in
                    ScrollView { rows }
                        .frame(maxHeight: 280)
                        .onChange(of: highlighted) { i in
                            if let i, i < matches.count { proxy.scrollTo(matches[i]) }
                        }
                }
            }
            .frame(width: 240)
            .onAppear(perform: installKeys)
            .onDisappear(perform: removeKeys)
        } else {
            rows.frame(minWidth: 160)
                .onAppear(perform: installKeys)
                .onDisappear(perform: removeKeys)
        }
    }
}

/// A row in SelectMenu's popover; highlighted by the pointer or arrow keys, like a menu item.
private struct MenuRow: View {
    let text: String
    let checked: Bool
    let highlighted: Bool
    let hover: (Bool) -> Void
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text(text)
                Spacer(minLength: 8)
                if checked { Image(systemName: "checkmark").font(.caption.weight(.semibold)) }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(highlighted ? 0.1 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover(perform: hover)
    }
}

/// A small icon button for row actions.
struct RowButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(.borderless)
            .help(help)
            .accessibilityLabel(help)
    }
}

extension View {
    /// Liquid Glass on macOS 26+, the classic prominent style before.
    @ViewBuilder func prominent() -> some View {
        if #available(macOS 26, *) { buttonStyle(.glassProminent) } else { buttonStyle(.borderedProminent) }
    }
}

/// Go's time.Time in JSON (RFC 3339, with or without fractional seconds).
/// The zero time ("0001-01-01T00:00:00Z") is nil.
func parseGoTime(_ s: String?) -> Date? {
    guard let s, !s.isEmpty else { return nil }
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    var d = f.date(from: s)
    if d == nil {
        f.formatOptions = [.withInternetDateTime]
        d = f.date(from: s)
    }
    guard let d, d > Date(timeIntervalSince1970: 0) else { return nil }
    return d
}

func relative(_ d: Date) -> String {
    RelativeDateTimeFormatter().localizedString(for: d, relativeTo: Date())
}

func plural(_ n: Int, _ one: String, _ many: String? = nil) -> String {
    "\(n.grouped) \(n == 1 ? one : (many ?? one + "s"))"
}

extension Int {
    /// Digit grouping per System Settings > Language & Region, including custom
    /// separators. `formatted()` ignores those overrides (it would show 1.928 in a
    /// region that defaults to dots even when the user chose commas); NumberFormatter
    /// honors them.
    var grouped: String { Self.formatter.string(from: NSNumber(value: self)) ?? String(self) }

    private static let formatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = .autoupdatingCurrent
        return f
    }()
}
