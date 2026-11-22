import AppKit
import SwiftUI

/// A color with a value for each appearance. Hex only, so the palette can be
/// checked for contrast without a screen.
public struct Tone: Sendable {
    public let light: UInt32
    public let dark: UInt32
    public init(light: UInt32, dark: UInt32) { self.light = light; self.dark = dark }

    public func hex(dark isDark: Bool) -> UInt32 { isDark ? dark : light }

    public var color: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: self.hex(dark: isDark))
        })
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// The surfaces and inks. Solid tones, no materials: they render the same
/// everywhere and the structure comes from tone and meaningful rules, not shadow.
public enum Palette {
    /// Behind everything (window, sidebar).
    public static let ground = Tone(light: 0xEDF0F3, dark: 0x0F1623)
    /// Where content sits (rows, fields, the popover).
    public static let surface = Tone(light: 0xFFFFFF, dark: 0x172033)
    public static let ink = Tone(light: 0x16202E, dark: 0xE8EDF5)
    /// Secondary text. At least 4.5:1 on both surfaces.
    public static let inkSecondary = Tone(light: 0x566173, dark: 0x9FABBD)
    public static let hairline = Tone(light: 0xD5DAE1, dark: 0x26324A)
    /// Errors and the Block action; never used for a tunnel.
    public static let danger = Tone(light: 0xC62F2F, dark: 0xFF7A7A)
    /// Warnings that are not failures.
    public static let warning = Tone(light: 0x8F5600, dark: 0xF7BC3A)
}

/// A tunnel's line color, like a metro line: it follows the tunnel everywhere
/// (its row, its chip on a list, the popover). For lines, dots and chips, never
/// for body text. Light values are darkened where the dark ones would be too pale.
public enum Line: String, CaseIterable, Codable, Sendable {
    case signal, cobalt, pine, saffron, plum

    public var name: String {
        switch self {
        case .signal: return "Signal"
        case .cobalt: return "Cobalt"
        case .pine: return "Pine"
        case .saffron: return "Saffron"
        case .plum: return "Plum"
        }
    }

    public var tone: Tone {
        switch self {
        case .signal: return Tone(light: 0xD6361E, dark: 0xFF7058)
        case .cobalt: return Tone(light: 0x2748D8, dark: 0x7B98FF)
        case .pine: return Tone(light: 0x0B7F62, dark: 0x34D3A6)
        case .saffron: return Tone(light: 0xA86C00, dark: 0xF7BC3A)
        case .plum: return Tone(light: 0x8A2D6B, dark: 0xE07FBF)
        }
    }

    public var color: Color { tone.color }
}

/// Radii by role: a field is not a row is not a panel.
public enum Radius {
    public static let control: CGFloat = 6
    public static let row: CGFloat = 10
    public static let panel: CGFloat = 14
}

public enum Space {
    public static let xs: CGFloat = 4
    public static let s: CGFloat = 8
    public static let m: CGFloat = 12
    public static let l: CGFloat = 16
    public static let xl: CGFloat = 24
    public static let xxl: CGFloat = 32
}

/// WCAG relative luminance and contrast, for the tests.
public enum Contrast {
    public static func luminance(_ hex: UInt32) -> Double {
        func channel(_ v: UInt32) -> Double {
            let c = Double(v) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel((hex >> 16) & 0xFF) + 0.7152 * channel((hex >> 8) & 0xFF) + 0.0722 * channel(hex & 0xFF)
    }

    public static func ratio(_ a: UInt32, _ b: UInt32) -> Double {
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }
}
