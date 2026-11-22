import CoreText
import SwiftUI

/// Instrument Sans (OFL), a variable font with width and weight axes.
public enum Fonts {
    public static let family = "Instrument Sans"

    /// Registers the font for this process. The shipped app has it at
    /// Contents/Resources/Fonts (build-app.sh); only the preview, which has no app
    /// bundle, falls back to SwiftPM's resource bundle. `Bundle.module` is never
    /// touched inside the app: its lookup fails in a signed bundle.
    public static func register() {
        let url = Bundle.main.url(forResource: "InstrumentSans", withExtension: "ttf", subdirectory: "Fonts")
            ?? Bundle.module.url(forResource: "InstrumentSans", withExtension: "ttf", subdirectory: "Fonts")
        guard let url else { return }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }
}

/// The type scale: five sizes with set weights.
public enum TypeScale {
    public static let title = Font.custom(Fonts.family, size: 22).weight(.semibold)
    public static let heading = Font.custom(Fonts.family, size: 15).weight(.semibold)
    public static let body = Font.custom(Fonts.family, size: 13.5)
    public static let bodyStrong = Font.custom(Fonts.family, size: 13.5).weight(.medium)
    /// Sidebar entries are larger than body text and sit on taller rows.
    public static let sidebar = Font.custom(Fonts.family, size: 14.5)
    public static let sidebarStrong = Font.custom(Fonts.family, size: 14.5).weight(.medium)
    public static let secondary = Font.custom(Fonts.family, size: 12)
    public static let caption = Font.custom(Fonts.family, size: 11).weight(.medium)
}
