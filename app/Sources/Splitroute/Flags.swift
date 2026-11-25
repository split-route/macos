import Foundation

/// A flag for a server, taken from its name: a flag emoji already in the name wins; else a country name as a whole word
/// ("Farhad Germany"); else a two-letter code written in capitals as a whole word ("DE-1"), from the list of places servers
/// are usually in. A code that isn't on that list is ignored on purpose: "WS" (WebSocket) is Samoa's, and a wrong flag is worse
/// than none.
enum Flags {
    private static let codes: Set<String> = [
        "US", "GB", "UK", "DE", "NL", "FR", "CA", "JP", "SG", "HK", "TR", "AE", "SE", "CH", "FI", "PL", "RU", "IR", "IN", "AU",
        "IT", "ES", "NO", "DK", "AT", "CZ", "RO", "UA", "BR", "KR", "TW", "IL", "BG", "LT", "LV", "EE", "IE", "PT", "GR", "HU",
        "ZA", "MX", "AR", "CL", "CO", "TH", "VN", "MY", "ID", "PH", "PK", "KZ", "AM", "GE", "AZ", "RS", "SK", "SI", "HR", "BE", "LU", "IS", "CY", "MD",
    ]

    /// English country names, longest first so "South Korea" is read before "Korea".
    private static let names: [(String, String)] = {
        let en = Locale(identifier: "en_US")
        var out: [(String, String)] = Locale.Region.isoRegions.map(\.identifier).filter { $0.count == 2 }.compactMap { code in
            en.localizedString(forRegionCode: code).map { ($0.lowercased(), code) }
        }
        out += [("holland", "NL"), ("uk", "GB"), ("usa", "US"), ("england", "GB"), ("emirates", "AE"), ("turkiye", "TR")]
        return out.sorted { $0.0.count > $1.0.count }
    }()

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

    /// The flag to put before a server's name: nil when the name has no sign of a place, or already shows a flag.
    static func prefix(for texts: [String?]) -> String? {
        let name = texts.first.flatMap { $0 }
        if let name, existing(in: name) != nil { return nil }
        for t in texts.compactMap({ $0 }) {
            if let e = existing(in: t) { return e }
        }
        for t in texts.compactMap({ $0 }) {
            if let c = code(in: t) { return emoji(code: c) }
        }
        return nil
    }

    /// The region code a name points to.
    static func code(in s: String) -> String? {
        let lower = s.lowercased()
        let words = lower.split { !$0.isLetter }.map(String.init)
        let joined = " " + words.joined(separator: " ") + " "
        for (name, code) in names where joined.contains(" " + name + " ") { return code == "UK" ? "GB" : code }
        for token in s.split(whereSeparator: { !$0.isLetter }) where token.count == 2 && token == token.uppercased() && codes.contains(String(token)) {
            return token == "UK" ? "GB" : String(token)
        }
        return nil
    }

    /// The two-letter code of a flag emoji, to put a country beside it ("DE").
    static func code(ofEmoji e: String) -> String? {
        let s = Array(e.unicodeScalars)
        guard s.count == 2, s.allSatisfy({ (0x1F1E6...0x1F1FF).contains($0.value) }) else { return nil }
        return String(String.UnicodeScalarView(s.map { UnicodeScalar($0.value - 0x1F1E6 + 65)! }))
    }
}
