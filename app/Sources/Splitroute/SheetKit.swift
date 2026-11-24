import AppKit
import Design
import SwiftUI

// The pieces of the add and edit list dialogs, built from the app's own tokens so a dialog looks like a page.

extension Action {
    /// How the action reads in a menu: a tunnel action follows the selected tunnel (a named one is picked on the page).
    var menuLabel: String { self == .tunnel ? "Active Server" : label }

    var dot: Color {
        switch self {
        case .none: return Palette.inkSecondary.color.opacity(0.5)
        case .direct: return Palette.success.color
        case .block: return Palette.danger.color
        case .tunnel: return Accent.color
        }
    }
}

extension View {
    func sheetBackground() -> some View { background(Palette.ground.color) }

    /// A text field's look: the surface tone, a hairline edge, the control radius.
    func fieldBox() -> some View {
        textFieldStyle(.plain)
            .font(TypeScale.body)
            .padding(.horizontal, Space.m).padding(.vertical, 7)
            .background(Glass.control, in: RoundedRectangle(cornerRadius: Radius.control)) // a field inside a panel: one step lighter than the panel
            .overlay(RoundedRectangle(cornerRadius: Radius.control).stroke(Glass.stroke, lineWidth: 1))
    }
}

/// The tabs at the top of the add dialog.
struct SheetTabs<T: Hashable & Identifiable & RawRepresentable>: View where T.RawValue == String {
    let options: [T]
    @Binding var selection: T

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options) { o in
                Text(o.rawValue)
                    .font(selection == o ? TypeScale.bodyStrong : TypeScale.body)
                    .foregroundStyle(selection == o ? Palette.ink.color : Palette.inkSecondary.color)
                    .padding(.horizontal, 14).padding(.vertical, 5)
                    .background {
                        if selection == o {
                            RoundedRectangle(cornerRadius: Radius.control - 2).fill(Glass.fill)
                                .overlay(RoundedRectangle(cornerRadius: Radius.control - 2).stroke(Glass.stroke, lineWidth: 1))
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { selection = o }
                    .accessibilityAddTraits(selection == o ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(2)
        .background(Glass.control, in: RoundedRectangle(cornerRadius: Radius.control))
    }
}

/// A search field in the surface tone.
struct SheetSearch: View {
    @Binding var text: String
    var prompt = "Search…"

    var body: some View {
        HStack(spacing: Space.s) {
            Image(systemName: "magnifyingglass").foregroundStyle(Palette.inkSecondary.color)
            TextField(prompt, text: $text).textFieldStyle(.plain).font(TypeScale.body)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.inkSecondary.color) }
                    .buttonStyle(.plain).accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, Space.m).padding(.vertical, 8)
        .background(Glass.fill, in: RoundedRectangle(cornerRadius: Radius.row))
        .overlay(RoundedRectangle(cornerRadius: Radius.row).stroke(Glass.stroke, lineWidth: 1))
    }
}

/// A labeled field row inside a Panel.
struct FieldRow: View {
    let title: String
    @Binding var text: String
    var prompt = ""

    var body: some View {
        FormRow(title) {
            TextField(title, text: $text, prompt: Text(prompt)).labelsHidden().fieldBox().frame(maxWidth: 320)
        }
    }
}

/// The action choice row of a form.
struct ActionRow: View {
    @Binding var action: Action

    var body: some View {
        FormRow("Action") {
            SelectMenu(title: action.menuLabel, options: Action.allCases, label: \.menuLabel, selected: action, dot: \.dot) { action = $0 }
        }
    }
}

/// Small print under a panel.
struct SheetNote: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(TypeScale.secondary).foregroundStyle(Palette.inkSecondary.color)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A dialog button: the primary one is the accent, the rest are outlined. A disabled one is dimmed.
struct SheetButton: View {
    let title: String
    var primary = false
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .modifier(SheetButtonStyle(primary: primary))
            .opacity(disabled ? 0.45 : 1)
            .disabled(disabled)
    }
}

private struct SheetButtonStyle: ViewModifier {
    let primary: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if primary { content.buttonStyle(SolidButtonStyle()).keyboardShortcut(.defaultAction) }
        else { content.buttonStyle(OutlineButtonStyle()).keyboardShortcut(.cancelAction) }
    }
}

/// The bottom bar of a dialog: an error or success line, then the buttons.
struct SheetBar<Buttons: View>: View {
    var error: String?
    var success: String?
    /// Something on the left of the bar, away from the buttons: a destructive action.
    var leading: AnyView?
    @ViewBuilder let buttons: Buttons

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            if let error, !error.isEmpty { NoteLine(.error, error) }
            if let success {
                Label(success, systemImage: "checkmark.circle.fill").font(TypeScale.secondary).foregroundStyle(Palette.success.color)
            }
            HStack(spacing: Space.s) {
                if let leading { leading }
                Spacer()
                buttons
            }
        }
        .padding(.horizontal, Space.xl).padding(.vertical, Space.l)
    }
}


/// An application as the list shows it: its icon and name, and where it is.
struct AppRow: View {
    let path: String
    let remove: () -> Void

    private var exists: Bool { FileManager.default.fileExists(atPath: path) }

    /// "Safari" for /Applications/Safari.app.
    static func name(_ path: String) -> String {
        let n = FileManager.default.displayName(atPath: path)
        return n.hasSuffix(".app") ? String(n.dropLast(4)) : n
    }

    var body: some View {
        HStack(spacing: Space.m) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(width: 30, height: 30)
                .opacity(exists ? 1 : 0.4).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(Self.name(path)).font(TypeScale.bodyStrong).foregroundStyle(Palette.ink.color).lineLimit(1)
                Text(exists ? path : "Not found: \(path)").font(TypeScale.secondary)
                    .foregroundStyle(exists ? Palette.inkSecondary.color : Palette.warning.color)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: Space.s)
            RowButton(symbol: "minus.circle", help: "Remove \(Self.name(path))", action: remove)
        }
        .padding(.horizontal, Space.l).padding(.vertical, Space.s)
    }
}


private struct ClosePageKey: EnvironmentKey { static let defaultValue: () -> Void = {} }

extension EnvironmentValues {
    /// Leaves the page of the Routing section that is open (adding or editing a list) and returns to the lists.
    var closePage: () -> Void {
        get { self[ClosePageKey.self] }
        set { self[ClosePageKey.self] = newValue }
    }
}


/// The glass behind a dialog: the window's own backdrop, darkened in the dark look and frosted in the light one, so a
/// dialog is light when the app is light.
private struct GlassSheetBackground: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View { Backdrop(material: .hudWindow, darkness: scheme == .dark ? 0.55 : 1.0) }
}

extension View {
    /// A dialog on liquid glass like the window, in the look the app has (light, dark or the system's).
    func glassSheet() -> some View {
        presentationBackground { GlassSheetBackground() }
    }
}
