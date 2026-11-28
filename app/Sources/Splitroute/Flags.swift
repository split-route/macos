import Foundation

/// The flag for a server: its country, found by the service from the address its name resolves to, so a wrong name
/// can't give a wrong flag. A flag emoji already in the name shows as part of it and gets no second one.
enum Flags {
    /// The flag emoji for a two-letter region code.
    static func emoji(code: String) -> String {
        let base: UInt32 = 0x1F1E6 - 65
        return String(code.uppercased().unicodeScalars.compactMap { UnicodeScalar(base + $0.value) }.map(Character.init))
    }

    /// A flag emoji already in `s`, if any (two regional indicators in a row).
    static func existing(in s: String) -> String? {
        let scalars = Array(s.unicodeScalars)
        for i in 0..<max(scalars.count - 1, 0) where (0x1F1E6...0x1F1FF).contains(scalars[i].value) && (0x1F1E6...0x1F1FF).contains(scalars[i + 1].value) {
            return String(String.UnicodeScalarView([scalars[i], scalars[i + 1]]))
        }
        return nil
    }

    /// The flag to put before a server's name: its country's, or nil when the country is unknown or the name already
    /// shows a flag. Names are never read for a place: a name is whatever the person or the provider typed.
    static func prefix(name: String, country: String) -> String? {
        guard country.count == 2, existing(in: name) == nil else { return nil }
        return emoji(code: country)
    }

    /// The two-letter code of a flag emoji, to put a country beside it ("DE").
    static func code(ofEmoji e: String) -> String? {
        let s = Array(e.unicodeScalars)
        guard s.count == 2, s.allSatisfy({ (0x1F1E6...0x1F1FF).contains($0.value) }) else { return nil }
        return String(String.UnicodeScalarView(s.map { UnicodeScalar($0.value - 0x1F1E6 + 65)! }))
    }
}
