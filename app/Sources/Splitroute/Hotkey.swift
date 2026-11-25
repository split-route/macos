import AppKit
import Design
import Carbon.HIToolbox
import SwiftUI

/// A key with modifiers, for the global shortcut that connects or disconnects.
struct Shortcut: Equatable, Codable {
    var keyCode: UInt32
    var modifiers: UInt32 // Carbon's: cmdKey, optionKey, controlKey, shiftKey
    var key: String // what the key types, for showing it

    /// "⌃⌥⌘C".
    var label: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + key.uppercased()
    }

    /// Carbon's modifier bits for an event's flags.
    static func carbon(_ f: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if f.contains(.command) { m |= UInt32(cmdKey) }
        if f.contains(.option) { m |= UInt32(optionKey) }
        if f.contains(.control) { m |= UInt32(controlKey) }
        if f.contains(.shift) { m |= UInt32(shiftKey) }
        return m
    }

    /// A shortcut needs command, option or control: Shift alone is just a capital letter, and a bare key would steal typing everywhere.
    var isUsable: Bool { modifiers & UInt32(cmdKey | optionKey | controlKey) != 0 }

    /// The shortcut a key press makes, or nil for one that can't be a global shortcut.
    static func from(_ e: NSEvent) -> Shortcut? {
        let s = Shortcut(keyCode: UInt32(e.keyCode), modifiers: carbon(e.modifierFlags.intersection(.deviceIndependentFlagsMask)),
                         key: keyName(e))
        return s.isUsable && !s.key.isEmpty ? s : nil
    }

    private static func keyName(_ e: NSEvent) -> String {
        switch Int(e.keyCode) {
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_F1...kVK_F20 where e.charactersIgnoringModifiers?.isEmpty ?? true: return "F\(e.keyCode)"
        default: return (e.charactersIgnoringModifiers ?? "").trimmingCharacters(in: .whitespaces)
        }
    }

    static let key = "globalShortcut"
    static var stored: Shortcut? {
        guard let d = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Shortcut.self, from: d)
    }
    static func store(_ s: Shortcut?) { UserDefaults.standard.set(s.flatMap { try? JSONEncoder().encode($0) }, forKey: key) }
}

/// The one global hotkey, through Carbon's `RegisterEventHotKey`: it needs no Accessibility permission (a global key monitor
/// does) and swallows the key so no other app sees it.
@MainActor
final class Hotkey {
    static let shared = Hotkey()
    var onPress: (() -> Void)?
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?

    /// Registers `s` in place of the old shortcut, or none for nil. Returns whether it worked: another app or the system may hold it.
    @discardableResult
    func register(_ s: Shortcut?) -> Bool {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        guard let s else { return true }
        if handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), hotkeyPressed, 1, &spec, nil, &handler)
        }
        let id = EventHotKeyID(signature: OSType(0x5352_4B59), id: 1) // "SRKY"
        return RegisterEventHotKey(s.keyCode, s.modifiers, id, GetApplicationEventTarget(), 0, &ref) == noErr
    }
}

/// Carbon wants a C function: it hops to the main actor and runs the handler.
private func hotkeyPressed(_: EventHandlerCallRef?, _: EventRef?, _: UnsafeMutableRawPointer?) -> OSStatus {
    DispatchQueue.main.async { Hotkey.shared.onPress?() }
    return noErr
}

/// The row's control: shows the shortcut, records a new one on click (a key with ⌘, ⌥ or ⌃; Esc cancels), clears it.
struct ShortcutRecorder: View {
    @State private var shortcut = Shortcut.stored
    @State private var recording = false
    @State private var monitor: Any?
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: Space.s) {
                Button(recording ? "Press the keys…" : (shortcut?.label ?? "Record Shortcut")) { toggle() }
                    .buttonStyle(OutlineButtonStyle()).monospacedDigit()
                    .accessibilityLabel("Global shortcut").accessibilityValue(shortcut?.label ?? "none")
                if shortcut != nil && !recording {
                    Button { set(nil) } label: { Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)) }
                        .buttonStyle(.plain).roundGlass(26).help("Remove the shortcut").accessibilityLabel("Remove the shortcut")
                }
            }
            if let problem { Text(problem).font(TypeScale.secondary).foregroundStyle(Palette.danger.color) }
        }
        .onDisappear { stop() }
    }

    private func toggle() {
        guard !recording else { return stop() }
        problem = nil
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode == UInt16(kVK_Escape) { stop(); return nil }
            if let s = Shortcut.from(e) { set(s); stop() } else { problem = "Use ⌘, ⌥ or ⌃ with a key." }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
    }

    private func set(_ s: Shortcut?) {
        let ok = Hotkey.shared.register(s)
        if ok { Shortcut.store(s); shortcut = s; problem = nil } else {
            _ = Hotkey.shared.register(shortcut) // keep the old one
            problem = "That shortcut is taken by the system or another app."
        }
    }
}
