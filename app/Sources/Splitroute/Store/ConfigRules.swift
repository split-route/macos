import Foundation

// The rules for lists: validation and the pure edits, ported from the daemon's config package. They work on
// canonical entry lines: the service's `canon_entries` turns what the user typed into canonical lines first (or
// refuses it), so the edits here never parse entry syntax themselves.

extension Config {
    static let defaultBaseURL = "https://raw.githubusercontent.com/split-route/routing-rules/release"
    static let defaultRefreshHours = 24
    static let maxRefreshHours = 7 * 24
    static let maxEntries = 100_000
    private static let maxNameLength = 64
    static let maxDescription = 120
    private static let maxURLLength = 2048

    /// What a new database starts with.
    static var initial: Config {
        var c = Config()
        c.lists = [RouteList(name: "ir-cidr", action: .direct)]
        return c
    }

    /// The release download address, without a trailing slash.
    var listsURL: String {
        guard let b = baseURL, !b.isEmpty else { return Config.defaultBaseURL }
        return b.hasSuffix("/") ? String(b.dropLast()) : b
    }

    private static let releaseName = try! NSRegularExpression(pattern: "^[a-z0-9][a-z0-9-]*$")

    /// Accepts https addresses without credentials (a password in the address would sit in the database).
    static func validateImportURL(_ raw: String) throws {
        guard raw.count <= maxURLLength else { throw StoreError("Import address longer than \(maxURLLength) characters.") }
        guard let u = URL(string: raw), u.scheme == "https", let host = u.host, !host.isEmpty else {
            throw StoreError("Import address \"\(raw)\": it must be https://host/...")
        }
        if u.user != nil || u.password != nil {
            throw StoreError("The import address must not hold a user name or password (the settings are readable by every local user).")
        }
    }

    /// Checks everything a write must keep true; the schema's constraints are a second line of defense.
    func validate() throws {
        if let b = baseURL, !b.isEmpty, !b.hasPrefix("https://") { throw StoreError("The release address must be https.") }
        if finalAction == .none { throw StoreError("The default route must go direct, be blocked or use a server.") }
        if let t = finalTunnel, !t.isEmpty {
            if finalAction != .tunnel { throw StoreError("Only the server action can name a server.") }
            if t.utf8.count > Config.maxNameLength || t.trimmingCharacters(in: .whitespaces) != t {
                throw StoreError("The server name \"\(t)\" is not valid.")
            }
        }
        var seen = Set<String>()
        for l in lists {
            let n = l.name
            if n.isEmpty || n.utf8.count > Config.maxNameLength || n.trimmingCharacters(in: .whitespaces) != n {
                throw StoreError("List name \"\(n)\": 1-\(Config.maxNameLength) characters, no leading or trailing spaces.")
            }
            if let d = l.description {
                if d.count > Config.maxDescription || d.contains(where: \.isNewline) || d.trimmingCharacters(in: .whitespaces) != d {
                    throw StoreError("List \"\(n)\": the description is one line of at most \(Config.maxDescription) characters.")
                }
                if !l.custom && l.importSource == nil { throw StoreError("List \"\(n)\": only custom lists and imports have a description of their own.") }
            }
            if l.custom && l.importSource != nil { throw StoreError("List \"\(n)\" is custom or an import, not both.") }
            if !l.custom, l.importSource == nil,
               Config.releaseName.firstMatch(in: n, range: NSRange(n.startIndex..., in: n)) == nil {
                throw StoreError("Invalid list name \"\(n)\".")
            }
            if !l.custom && !l.entries.isEmpty { throw StoreError("List \"\(n)\": only custom lists have entries.") }
            if let t = l.tunnel, !t.isEmpty {
                if l.action != .tunnel { throw StoreError("List \"\(n)\": only a server list can name a server.") }
                if t.utf8.count > Config.maxNameLength || t.trimmingCharacters(in: .whitespaces) != t {
                    throw StoreError("List \"\(n)\": the server name \"\(t)\" is not valid.")
                }
            }
            if !seen.insert(n).inserted { throw StoreError("List \"\(n)\" is listed twice.") }
            if let im = l.importSource {
                try Config.validateImportURL(im.url)
                if let h = im.refreshHours, h < 0 || h > Config.maxRefreshHours {
                    throw StoreError("List \"\(n)\": refresh must be 1-\(Config.maxRefreshHours) hours.")
                }
            }
            if l.entries.count > Config.maxEntries {
                throw StoreError("List \"\(n)\" has \(l.entries.count) lines; the limit is \(Config.maxEntries) entries.")
            }
        }
    }

    // MARK: Edits. Each returns a new Config; the caller validates and writes it.

    private func index(_ name: String) -> Int? { lists.firstIndex { $0.name == name } }

    private func adding(_ l: RouteList) throws -> Config {
        if index(l.name) != nil { throw StoreError("List \"\(l.name)\" already exists.") }
        var c = self
        c.lists.append(l)
        try c.validate()
        return c
    }

    func creating(_ name: String, _ a: Action, description: String? = nil) throws -> Config {
        var l = RouteList(name: name, action: a, custom: true)
        l.description = description?.nilIfEmpty
        return try adding(l)
    }

    func enablingRelease(_ name: String, _ a: Action) throws -> Config { try adding(RouteList(name: name, action: a)) }

    func importing(_ name: String, _ a: Action, url: String, description: String? = nil) throws -> Config {
        var l = RouteList(name: name, action: a)
        l.description = description?.nilIfEmpty
        l.importSource = ImportSource(url: url, refreshHours: nil)
        return try adding(l)
    }

    func removing(_ name: String) throws -> Config {
        guard let i = index(name) else { throw StoreError("No list named \"\(name)\".") }
        var c = self
        c.lists.remove(at: i)
        return c
    }

    /// Release lists are named by the release, so only custom lists and imports can be renamed.
    func renaming(_ name: String, to new: String) throws -> Config {
        guard let i = index(name) else { throw StoreError("No list named \"\(name)\".") }
        if !lists[i].custom && lists[i].importSource == nil {
            throw StoreError("\"\(name)\" is a release list; only custom lists and imports can be renamed.")
        }
        if new != name && index(new) != nil { throw StoreError("List \"\(new)\" already exists.") }
        var c = self
        c.lists[i].name = new
        try c.validate()
        return c
    }

    /// Where traffic no list matches goes. `tunnel` names a tunnel for the tunnel action; nil is the selected one.
    func settingFinal(_ a: Action, tunnel: String?) throws -> Config {
        var c = self
        c.finalAction = a
        c.finalTunnel = (tunnel?.isEmpty ?? true) ? nil : tunnel
        try c.validate()
        return c
    }

    /// Points an import at another address; its entries are dropped until the new one is downloaded (the store does that).
    func settingImportURL(_ name: String, to url: String) throws -> Config {
        guard let i = index(name), lists[i].importSource != nil else { throw StoreError("\"\(name)\" is not a list from a URL.") }
        try Config.validateImportURL(url)
        var c = self
        c.lists[i].importSource?.url = url
        try c.validate()
        return c
    }

    /// A custom list's or import's description; empty clears it.
    func settingDescription(_ name: String, _ text: String?) throws -> Config {
        guard let i = index(name) else { throw StoreError("No list named \"\(name)\".") }
        var c = self
        c.lists[i].description = text?.nilIfEmpty
        try c.validate()
        return c
    }

    /// `tunnel` names the tunnel for the tunnel action; nil means the default tunnel, and it must be nil for the others.
    func settingAction(_ name: String, _ a: Action, tunnel: String?) throws -> Config {
        guard let i = index(name) else { throw StoreError("No list named \"\(name)\".") }
        var c = self
        c.lists[i].action = a
        c.lists[i].tunnel = (tunnel?.isEmpty ?? true) ? nil : tunnel
        try c.validate()
        return c
    }

    func moving(_ name: String, to pos: Int) throws -> Config {
        guard let i = index(name) else { throw StoreError("No list named \"\(name)\".") }
        guard pos >= 0, pos < lists.count else { throw StoreError("Position \(pos + 1) is out of range (1-\(lists.count)).") }
        var c = self
        let l = c.lists.remove(at: i)
        c.lists.insert(l, at: pos)
        return c
    }

    private func customIndex(_ name: String) throws -> Int {
        guard let i = index(name) else { throw StoreError("No list named \"\(name)\".") }
        if let im = lists[i].importSource { throw StoreError("\"\(name)\" is an import; its entries come from \(im.url).") }
        if !lists[i].custom { throw StoreError("\"\(name)\" is a release list; entries can only be changed in custom lists.") }
        return i
    }

    /// Appends canonical lines to a custom list. Entries already there are skipped; "#" lines are notes for the entry
    /// after them.
    func addingEntries(_ name: String, _ lines: [String]) throws -> (Config, EntryEdit) {
        let i = try customIndex(name)
        var ed = EntryEdit()
        var have = Set(lists[i].entries.filter { !$0.hasPrefix("#") && !$0.isEmpty })
        var entries = lists[i].entries
        var notes: [String] = []
        var added = 0, dups = 0
        for raw in lines {
            let l = raw.trimmingCharacters(in: .whitespaces)
            if l.isEmpty { continue }
            if l.hasPrefix("#") { notes.append(l); continue }
            if !have.insert(l).inserted { dups += 1; notes = []; continue }
            entries += notes + [l]
            notes = []
            added += 1
        }
        if have.count > Config.maxEntries {
            throw StoreError("List \"\(name)\" would have \(have.count) entries; the limit is \(Config.maxEntries) (use an import for big lists).")
        }
        ed.added = added == 0 ? nil : added
        ed.duplicates = dups == 0 ? nil : dups
        var c = self
        c.lists[i].entries = entries
        try c.validate()
        return (c, ed)
    }

    /// Replaces a custom list's entries as adding them to an empty list would. "#" notes after the last entry are kept.
    func settingEntries(_ name: String, _ lines: [String]) throws -> (Config, EntryEdit) {
        let i = try customIndex(name)
        var c = self
        c.lists[i].entries = []
        var (out, ed) = try c.addingEntries(name, lines)
        var tail: [String] = []
        for raw in lines.reversed() {
            let l = raw.trimmingCharacters(in: .whitespaces)
            if l.isEmpty { continue }
            if !l.hasPrefix("#") { break }
            tail.insert(l, at: 0)
        }
        out.lists[i].entries += tail
        ed.skipped = nil
        return (out, ed)
    }

    /// Removes canonical lines from a custom list, with the "#" notes just before them.
    func removingEntries(_ name: String, _ lines: [String]) throws -> (Config, EntryEdit) {
        let i = try customIndex(name)
        var ed = EntryEdit()
        var drop: [String: String] = [:]
        for raw in lines {
            let l = raw.trimmingCharacters(in: .whitespaces)
            if l.isEmpty || l.hasPrefix("#") { continue }
            drop[l] = l
        }
        var out: [String] = [], notes: [String] = []
        var removed = 0
        for l in lists[i].entries {
            let t = l.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("#") || t.isEmpty { notes.append(l); continue }
            if drop.removeValue(forKey: t) != nil { removed += 1; notes = []; continue }
            out += notes + [l]
            notes = []
        }
        out += notes
        ed.removed = removed == 0 ? nil : removed
        ed.notFound = drop.isEmpty ? nil : drop.values.sorted()
        var c = self
        c.lists[i].entries = out
        try c.validate()
        return (c, ed)
    }
}

// MARK: Entries

/// The stored form of a custom list's entries: a kind and a value per row, with the "#" lines before it as a note.
enum Entries {
    struct Row: Equatable { var kind: String; var value: String; var note: String }

    private static let ipv4 = try! NSRegularExpression(pattern: #"^\d{1,3}(\.\d{1,3}){3}(/\d{1,2})?$"#)

    /// The kind of a canonical entry line: `full:name`, `AS123`, an address or range, or a domain with its subdomains.
    static func kind(_ line: String) -> String {
        if line.hasPrefix("full:") { return "domain" }
        if line.hasPrefix("AS"), line.dropFirst(2).allSatisfy(\.isNumber), line.count > 2 { return "asn" }
        if line.contains(":") || ipv4.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil { return "cidr" }
        return "domain_suffix"
    }

    /// The stored value: the line without its kind marker.
    static func value(_ line: String) -> String {
        switch kind(line) {
        case "domain": return String(line.dropFirst(5))
        case "asn": return String(line.dropFirst(2))
        default: return line
        }
    }

    /// The line a stored entry reads back as.
    static func text(kind: String, value: String) -> String {
        switch kind {
        case "domain": return "full:" + value
        case "asn": return "AS" + value
        default: return value
        }
    }

    static func noteLines(_ note: String) -> [String] {
        note.isEmpty ? [] : note.split(separator: "\n", omittingEmptySubsequences: false).map { "# \($0)".trimmingCharacters(in: .whitespaces) }
    }

    /// Turns canonical lines into rows, dropping duplicates. "#" lines become the note of the next entry; those after
    /// the last entry become the list's note.
    static func rows(_ lines: [String]) throws -> (rows: [Row], note: String) {
        var out: [Row] = []
        var pending: [String] = []
        var seen = Set<String>()
        for raw in lines {
            let l = raw.trimmingCharacters(in: .whitespaces)
            if l.isEmpty { continue }
            if l.hasPrefix("#") {
                pending.append(String(l.dropFirst()).trimmingCharacters(in: .whitespaces))
                continue
            }
            let k = kind(l), v = value(l)
            guard v.utf8.count >= 1, v.utf8.count <= 253 else { throw StoreError("\"\(l)\" is not a valid entry.") }
            if seen.insert(k + " " + v).inserted {
                out.append(Row(kind: k, value: v, note: pending.joined(separator: "\n")))
                pending = []
            }
        }
        return (out, pending.joined(separator: "\n"))
    }
}

// MARK: The catalog (content, not engine)

/// Titles and descriptions of the release lists, and the action most people want (see the release's sources.yaml).
enum Catalog {
    static let all: [ListInfo] = ([
        ("ir-cidr", "Iran IP ranges", "Addresses registered in Iran. Direct keeps Iranian sites off the server.", .direct),
        ("ir-domains", "Iranian websites", "Iranian domains, .ir and sites hosted in Iran.", .direct),
        ("ir-injected", "Iran block pages", "Addresses Iran's DNS returns for filtered sites.", .block),
        ("private", "Local networks", "Private and special-use ranges, such as your home network.", .direct),
        ("malware", "Malware", "Known malware and command servers.", .block),
        ("phishing", "Phishing", "Sites that imitate others to steal passwords.", .block),
        ("cryptominers", "Crypto miners", "In-browser cryptocurrency miners.", .block),
        ("ads", "Ads and trackers", "Ad networks and trackers, Iranian ones included.", .block),
        ("ads-lite", "Ads and trackers (lite)", "A smaller ads list for low-memory devices.", .block),
        ("tracking", "Device telemetry", "Telemetry from Windows, phones and smart TVs.", .block),
        ("sanctioned", "Sites that block Iran", "Services that refuse Iranian IP addresses.", .tunnel),
        ("social", "Social networks", "Major social networks and their apps.", .tunnel),
        ("nsfw", "Adult content", "Adult websites.", .block),
        ("arvancloud", "ArvanCloud", "Iranian CDN and cloud, including its servers abroad.", .direct),
        ("parspack", "ParsPack", "Iranian hosting and cloud servers.", .direct),
        ("derak", "Derak Cloud", "Iranian CDN.", .direct),
        ("cloudflare", "Cloudflare", "Cloudflare's CDN and services.", .tunnel),
        ("cloudfront", "Amazon CloudFront", "Amazon's CDN.", .tunnel),
        ("fastly", "Fastly", "Fastly's CDN.", .tunnel),
        ("gcore", "Gcore", "Gcore's CDN and cloud.", .tunnel),
        ("telegram", "Telegram", "Telegram's servers.", .tunnel),
        ("tor-exit", "Tor exit nodes", "Addresses Tor traffic leaves the Tor network from.", .tunnel),
        ("netflix", "Netflix", "Netflix's own network.", .tunnel),
    ] as [(String, String, String, Action)]).map { ListInfo(name: $0.0, title: $0.1, description: $0.2, action: $0.3) }

    /// The entry for `name`, or one with the bare name as its title for a list the release added after this build.
    static func describe(_ name: String) -> ListInfo {
        all.first { $0.name == name } ?? ListInfo(name: name, title: name, description: "", action: .direct)
    }
}
