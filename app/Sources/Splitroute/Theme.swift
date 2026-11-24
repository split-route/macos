import AppKit

/// The look the user picked. Stored in the defaults under `key`; applied to the whole app (window, menu bar panel,
/// sheets) through `NSApp.appearance`, so every view follows it. System means no override.
enum Theme: String, CaseIterable {
    case system, light, dark

    static let key = "theme"

    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var appearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    /// The saved choice; an unknown value is System.
    static var stored: Theme { Theme(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .system }

    @MainActor func apply() { NSApp.appearance = appearance }
}
