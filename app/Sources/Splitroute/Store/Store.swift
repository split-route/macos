import Foundation
import GRDB

/// A refusal the user can read: validation, a name taken, a tunnel in use.
struct StoreError: LocalizedError, Equatable {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct StoreTunnel: Equatable, Identifiable {
    var id: Int64
    var name: String
    /// The core's protocol name ("openvpn", "vless", ...).
    var kind: String
    /// Hash of the profile or options file; checked before it is sent to the service.
    var sha: String
    var remotes: [String] = []
    var needsAuth = false
    var keyEncrypted = false
    var autoConnect = false
    var subscriptionID: Int64?
    var warning = ""
    /// OpenVPN only: "host" or "host:port" used in place of the profile's remote lines. Empty: the profile's.
    var serverOverride = ""

    /// The core's tunnel ID: the app's row ID, never reused.
    var coreID: String { "t\(id)" }
    var isOpenVPN: Bool { kind == "openvpn" }
}

struct StoreSubscription: Equatable, Identifiable {
    var id: Int64
    var name: String
    var lastError: String
    var updatedAt: String
}

/// An import's download state (Go: store.ImportState).
struct ImportState: Equatable {
    var name: String
    var url: String
    var refreshHours: Int
    var etag = ""
    var lastModified = ""
    var sha256 = ""
    var fetchedAt = ""
    var checkedAt = ""
    var lastError = ""
    var force = false
    var skipped = 0
    var entries = 0
    /// The import is a rule-set (its bytes are the content, not entries).
    var hasRuleSet = false

    /// A failed download is tried again after 15 minutes, not after the whole refresh time.
    static let retryAfterError: TimeInterval = 15 * 60

    var refresh: TimeInterval { TimeInterval(refreshHours == 0 ? Config.defaultRefreshHours : refreshHours) * 3600 }

    /// Whether to download it now: asked for, never tried, or its refresh time (or the retry time after a failure) passed.
    func isDue(_ now: Date = Date()) -> Bool {
        let wait = lastError.isEmpty ? refresh : min(refresh, ImportState.retryAfterError)
        guard !force, let checked = Store.parse(checkedAt) else { return true }
        return now.timeIntervalSince(checked) >= wait
    }
}

/// The settings database: lists, tunnels, subscriptions, the VPN switch. The app owns it; the service
/// never sees it. Every change validates and commits in one transaction.
final class Store {
    static let maxTunnels = 5000

    let queue: DatabaseQueue
    let path: String

    /// Opens the database at `path` (made 0600 in a 0700 directory), checks it and applies pending migrations. A
    /// database that fails its integrity check, or one from a newer app, is an error, never reset.
    init(path: String) throws {
        self.path = path
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var config = Configuration()
        config.busyMode = .timeout(5) // a second launch waits for the first one's migration instead of failing
        queue = try DatabaseQueue(path: path, configuration: config)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        let ok = try queue.read { try String.fetchOne($0, sql: "PRAGMA quick_check") }
        guard ok == "ok" else { throw StoreError("The settings database is damaged (\(ok ?? "no answer")). It was left as it is: \(path)") }
        try migrate()
        try initialize()
    }

    // MARK: Migrations

    private func migrate() throws {
        let ms = Schema.migrations
        let have = try queue.read { try Int.fetchOne($0, sql: "PRAGMA user_version") ?? 0 }
        guard have <= ms.count else {
            throw StoreError("The settings database is from a newer Splitroute (schema \(have), this one knows \(ms.count)). Update the app.")
        }
        for v in have..<ms.count { try apply(version: v + 1, sql: ms[v]) }
    }

    /// One migration and its version bump in one immediate transaction, so a crash leaves a whole version and a second
    /// launch waits. A migration that rebuilds a table runs with foreign keys off, and the database is copied to
    /// `<db>.v<N>` first: inside the transaction, after the version check, so the file on disk is exactly the committed
    /// state, no other process can write, and a launch that finds the migration already applied never replaces the copy.
    private func apply(version: Int, sql: String) throws {
        let rebuild = sql.hasPrefix(Schema.foreignKeysOff)
        try queue.writeWithoutTransaction { db in
            if rebuild { try db.execute(sql: "PRAGMA foreign_keys = OFF") }
            do {
                try db.inTransaction(.immediate) {
                    let cur = try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0
                    if cur >= version { return .rollback }
                    if rebuild { try self.backup(db, version: version - 1) }
                    try db.execute(sql: sql)
                    if rebuild, let bad = try Row.fetchOne(db, sql: "PRAGMA foreign_key_check") {
                        throw StoreError("Foreign key violations after migration \(version) (a row of \(bad[0] as String? ?? "?") that references \(bad[2] as String? ?? "?")).")
                    }
                    try db.execute(sql: "PRAGMA user_version = \(version)")
                    return .commit
                }
            } catch {
                if rebuild { try? db.execute(sql: "PRAGMA foreign_keys = ON") }
                throw error
            }
            if rebuild {
                try db.execute(sql: "PRAGMA foreign_keys = ON")
                guard try Int.fetchOne(db, sql: "PRAGMA foreign_keys") == 1 else { throw StoreError("Foreign keys could not be turned back on.") }
            }
        }
    }

    /// A database with no settings (just created) has nothing to keep.
    private func backup(_ db: Database, version: Int) throws {
        guard try db.tableExists("settings"), try Int.fetchOne(db, sql: "SELECT count(*) FROM settings") ?? 0 > 0 else { return }
        let dst = "\(path).v\(version)"
        try? FileManager.default.removeItem(atPath: dst)
        try FileManager.default.copyItem(atPath: path, toPath: dst)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dst)
    }

    /// A new database gets the default settings and the default list.
    private func initialize() throws {
        try queue.write { db in
            guard try Int.fetchOne(db, sql: "SELECT count(*) FROM settings") == 0 else { return }
            let now = Store.stamp()
            try db.execute(sql: "INSERT INTO settings (id, migrated_from, created_at) VALUES (1, '', ?)", arguments: [now])
            try Store.write(db, Config.initial)
        }
    }

    // MARK: Time

    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    static func stamp(_ d: Date = Date()) -> String { formatter.string(from: d) }
    static func parse(_ s: String) -> Date? { formatter.date(from: s) ?? ISO8601DateFormatter().date(from: s) }

    // MARK: Config

    func config() throws -> Config { try queue.read { try Store.read($0) } }

    /// Reads the config, changes it with `f`, validates and writes it in one transaction.
    @discardableResult
    func update(_ f: (Config) throws -> Config) throws -> Config {
        try queue.write { db in
            var cfg = try Store.read(db)
            cfg = try f(cfg)
            try cfg.validate()
            try Store.write(db, cfg)
            return cfg
        }
    }

    static func read(_ db: Database) throws -> Config {
        guard let s = try Row.fetchOne(db, sql: """
            SELECT s.base_url, s.disabled, s.final_action, s.block_quic, s.block_stun, s.tls_fingerprint, t.name AS final_tunnel
            FROM settings s LEFT JOIN tunnels t ON t.id = s.final_tunnel_id WHERE s.id = 1
            """) else {
            throw StoreError("The settings database has no settings.")
        }
        var cfg = Config()
        let base: String = s["base_url"]
        cfg.baseURL = base.isEmpty ? nil : base
        cfg.disabled = (s["disabled"] as Int) == 1
        cfg.finalAction = Action(rawValue: s["final_action"]) ?? .tunnel
        cfg.finalTunnel = s["final_tunnel"]
        cfg.blockQUIC = (s["block_quic"] as Int) == 1
        cfg.blockSTUN = (s["block_stun"] as Int) == 1
        cfg.tlsFingerprint = s["tls_fingerprint"]
        let rows = try Row.fetchAll(db, sql: """
            SELECT l.id, l.name, l.source, l.action, t.name AS tunnel, l.description, l.builder, (l.ruleset IS NOT NULL) AS has_ruleset,
                   i.url, i.refresh_hours
            FROM lists l LEFT JOIN import_sources i ON i.list_id = l.id LEFT JOIN tunnels t ON t.id = l.tunnel_id
            ORDER BY l.position, l.id
            """)
        for r in rows {
            var l = RouteList(name: r["name"], action: Action(rawValue: r["action"]) ?? .direct)
            l.tunnel = r["tunnel"]
            l.description = (r["description"] as String).nilIfEmpty
            l.ruleSet = (r["has_ruleset"] as Int) == 1
            switch r["source"] as String {
            case "custom":
                l.custom = true
                let json: String = r["builder"]
                if !json.isEmpty, let spec = try? JSONDecoder().decode(RuleSpec.self, from: Data(json.utf8)) { l.rules = spec }
            case "import":
                l.importSource = ImportSource(url: r["url"] ?? "", refreshHours: (r["refresh_hours"] as Int?).flatMap { $0 == 0 ? nil : $0 })
            default: break
            }
            cfg.lists.append(l) // entries and rule-set bytes stay in the database
        }
        try cfg.validate()
        return cfg
    }

    /// Replaces the stored settings with `cfg` (already validated). Lists keep their ID and creation time; lists missing
    /// from `cfg` are deleted with their entries. An import keeps its downloaded entries unless its address changed.
    static func write(_ db: Database, _ cfg: Config) throws {
        let now = stamp()
        var finalID: Int64?
        if let name = cfg.finalTunnel, !name.isEmpty {
            guard let id = try Int64.fetchOne(db, sql: "SELECT id FROM tunnels WHERE name = ?", arguments: [name]) else {
                throw StoreError("Default route: no server named \"\(name)\".")
            }
            finalID = id
        }
        try db.execute(sql: "UPDATE settings SET base_url = ?, disabled = ?, final_action = ?, final_tunnel_id = ?, block_quic = ?, block_stun = ?, tls_fingerprint = ? WHERE id = 1",
                       arguments: [cfg.baseURL ?? "", cfg.disabled ? 1 : 0, cfg.finalAction.rawValue, finalID, cfg.blockQUIC ? 1 : 0, cfg.blockSTUN ? 1 : 0, cfg.tlsFingerprint])
        var existing: [String: (id: Int64, source: String)] = [:]
        for r in try Row.fetchAll(db, sql: "SELECT id, name, source FROM lists") { existing[r["name"]] = (r["id"], r["source"]) }
        for (pos, l) in cfg.lists.enumerated() {
            let source = l.custom ? "custom" : (l.importSource != nil ? "import" : "release")
            let builder = l.custom && !l.rules.isEmpty ? (String(data: try JSONEncoder().encode(l.rules), encoding: .utf8) ?? "") : ""
            var tunnelID: Int64?
            if let name = l.tunnel, !name.isEmpty {
                guard let id = try Int64.fetchOne(db, sql: "SELECT id FROM tunnels WHERE name = ?", arguments: [name]) else {
                    throw StoreError("List \"\(l.name)\": no server named \"\(name)\".")
                }
                tunnelID = id
            }
            var id: Int64
            if let old = existing.removeValue(forKey: l.name) {
                id = old.id
                try db.execute(sql: "UPDATE lists SET source = ?, action = ?, tunnel_id = ?, position = ?, builder = ?, description = ?, updated_at = ? WHERE id = ?",
                               arguments: [source, l.action.rawValue, tunnelID, pos, builder, l.description ?? "", now, id])
                if source != "import" || old.source != "import" { try db.execute(sql: "DELETE FROM entries WHERE list_id = ?", arguments: [id]) }
                if source != "import" && old.source == "import" { try db.execute(sql: "DELETE FROM import_sources WHERE list_id = ?", arguments: [id]) }
            } else {
                try db.execute(sql: "INSERT INTO lists (name, source, action, tunnel_id, position, builder, description, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                               arguments: [l.name, source, l.action.rawValue, tunnelID, pos, builder, l.description ?? "", now, now])
                id = db.lastInsertedRowID
            }
            if let im = l.importSource { try writeImport(db, id, im) }
        }
        for old in existing.values { try db.execute(sql: "DELETE FROM lists WHERE id = ?", arguments: [old.id]) }
    }

    /// A new address drops the old entries and download state: entries from another source would mislead, so the
    /// list routes nothing until the new address is downloaded.
    private static func writeImport(_ db: Database, _ id: Int64, _ im: ImportSource) throws {
        let hours = im.refreshHours ?? 0
        guard let url = try String.fetchOne(db, sql: "SELECT url FROM import_sources WHERE list_id = ?", arguments: [id]) else {
            try db.execute(sql: "INSERT INTO import_sources (list_id, url, refresh_hours) VALUES (?, ?, ?)", arguments: [id, im.url, hours])
            return
        }
        if url != im.url {
            try db.execute(sql: "DELETE FROM entries WHERE list_id = ?", arguments: [id])
            try db.execute(sql: "UPDATE lists SET ruleset = NULL WHERE id = ?", arguments: [id])
            try db.execute(sql: """
                UPDATE import_sources SET url = ?, refresh_hours = ?, etag = '', last_modified = '', sha256 = '', fetched_at = '',
                checked_at = '', last_error = '', force = 0, skipped = 0 WHERE list_id = ?
                """, arguments: [im.url, hours, id])
        } else {
            try db.execute(sql: "UPDATE import_sources SET refresh_hours = ? WHERE list_id = ?", arguments: [hours, id])
        }
    }

    /// Renames a list in place, keeping its row: an import's downloaded entries and state live only in the database,
    /// and `update` would see a new name as a new list and drop them.
    func renameList(_ old: String, to new: String) throws {
        try queue.write { db in
            guard try Int.fetchOne(db, sql: "SELECT 1 FROM lists WHERE name = ?", arguments: [old]) != nil else {
                throw StoreError("No list named \"\(old)\".")
            }
            if new != old, try Int.fetchOne(db, sql: "SELECT 1 FROM lists WHERE name = ?", arguments: [new]) != nil {
                throw StoreError("List \"\(new)\" already exists.")
            }
            try db.execute(sql: "UPDATE lists SET name = ?, updated_at = ? WHERE name = ?", arguments: [new, Store.stamp(), old])
        }
    }

    // MARK: Imports

    /// Entry counts per import, kept while its downloaded copy (the hash) is the same: counting a big import's rows every
    /// time the status is read (every few seconds) would be most of the app's work.
    private let countLock = NSLock()
    private var counts: [Int64: (sha: String, count: Int)] = [:]

    func imports() throws -> [ImportState] {
        try queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT l.id, l.name, i.url, i.refresh_hours, i.etag, i.last_modified, i.sha256, i.fetched_at, i.checked_at, i.last_error, i.force, i.skipped,
                       (l.ruleset IS NOT NULL) AS has_ruleset
                FROM import_sources i JOIN lists l ON l.id = i.list_id ORDER BY l.position, l.id
                """).map { r in
                let id: Int64 = r["id"]
                let sha: String = r["sha256"]
                countLock.lock()
                let cached = counts[id]
                countLock.unlock()
                var n = cached?.count ?? 0
                if cached == nil || cached?.sha != sha || sha.isEmpty {
                    n = try Int.fetchOne(db, sql: "SELECT count(*) FROM entries WHERE list_id = ?", arguments: [id]) ?? 0
                    countLock.lock()
                    counts[id] = (sha, n)
                    countLock.unlock()
                }
                return ImportState(name: r["name"], url: r["url"], refreshHours: r["refresh_hours"], etag: r["etag"], lastModified: r["last_modified"],
                                   sha256: sha, fetchedAt: r["fetched_at"], checkedAt: r["checked_at"], lastError: r["last_error"],
                                   force: (r["force"] as Int) == 1, skipped: r["skipped"], entries: n,
                                   hasRuleSet: (r["has_ruleset"] as Int) == 1)
            }
        }
    }

    /// An import's entries as the lines the service reads (canonical, no notes).
    func importLines(_ name: String) throws -> [String] {
        try queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT e.kind, e.value FROM entries e JOIN lists l ON l.id = e.list_id
                WHERE l.name = ? AND l.source = 'import' ORDER BY e.position
                """, arguments: [name]).map { Entries.text(kind: $0["kind"], value: $0["value"]) }
        }
    }

    func forceImport(_ name: String) throws {
        try queue.write { db in
            try db.execute(sql: "UPDATE import_sources SET force = 1 WHERE list_id = (SELECT id FROM lists WHERE name = ? AND source = 'import')", arguments: [name])
            guard db.changesCount > 0 else { throw StoreError("No import named \"\(name)\".") }
        }
    }

    /// Replaces an import's entries with a download, if the import still has this address (it may have been removed or
    /// re-pointed while the download ran: then nothing is stored and `false` comes back).
    @discardableResult
    func saveDownload(name: String, url: String, lines: [String], etag: String, lastModified: String, sha256: String, skipped: Int) throws -> Bool {
        try queue.write { db in
            guard let id = try Int64.fetchOne(db, sql: "SELECT l.id FROM lists l JOIN import_sources i ON i.list_id = l.id WHERE l.name = ? AND i.url = ?", arguments: [name, url]) else { return false }
            try db.execute(sql: "DELETE FROM entries WHERE list_id = ?", arguments: [id])
            let (rows, _) = try Entries.rows(lines)
            for (i, e) in rows.enumerated() {
                try db.execute(sql: "INSERT INTO entries (list_id, position, kind, value, note) VALUES (?, ?, ?, ?, '')", arguments: [id, i, e.kind, e.value])
            }
            let now = Store.stamp()
            try db.execute(sql: """
                UPDATE import_sources SET etag = ?, last_modified = ?, sha256 = ?, fetched_at = ?, checked_at = ?, last_error = '', force = 0, skipped = ?
                WHERE list_id = ?
                """, arguments: [etag, lastModified, sha256, now, now, skipped, id])
            return true
        }
    }

    /// Stores a rule-set (the binary file the service checked) for a list, as it is. nil removes it.
    func setRuleSet(name: String, data: Data?) throws {
        try queue.write { try $0.execute(sql: "UPDATE lists SET ruleset = ?, updated_at = ? WHERE name = ?", arguments: [data, Store.stamp(), name]) }
    }

    func ruleSetData(_ name: String) throws -> Data? {
        try queue.read { try Data.fetchOne($0, sql: "SELECT ruleset FROM lists WHERE name = ?", arguments: [name]) }
    }

    /// Like `saveDownload`, for an import that is a rule-set: its bytes replace what the list had, entries and all.
    @discardableResult
    func saveRuleSetDownload(name: String, url: String, data: Data, etag: String, lastModified: String, sha256: String) throws -> Bool {
        try queue.write { db in
            guard let id = try Int64.fetchOne(db, sql: "SELECT l.id FROM lists l JOIN import_sources i ON i.list_id = l.id WHERE l.name = ? AND i.url = ?", arguments: [name, url]) else { return false }
            try db.execute(sql: "DELETE FROM entries WHERE list_id = ?", arguments: [id])
            try db.execute(sql: "UPDATE lists SET ruleset = ?, updated_at = ? WHERE id = ?", arguments: [data, Store.stamp(), id])
            let now = Store.stamp()
            try db.execute(sql: """
                UPDATE import_sources SET etag = ?, last_modified = ?, sha256 = ?, fetched_at = ?, checked_at = ?, last_error = '', force = 0, skipped = 0
                WHERE list_id = ?
                """, arguments: [etag, lastModified, sha256, now, now, id])
            return true
        }
    }

    /// Records a download attempt that kept the last good copy (not modified, or failed with `error`).
    func markChecked(name: String, url: String, etag: String, lastModified: String, error: String) throws {
        try queue.write { db in
            try db.execute(sql: """
                UPDATE import_sources SET checked_at = ?, last_error = ?, force = 0, etag = CASE WHEN ? = '' THEN etag ELSE ? END,
                last_modified = CASE WHEN ? = '' THEN last_modified ELSE ? END
                WHERE url = ? AND list_id = (SELECT id FROM lists WHERE name = ?)
                """, arguments: [Store.stamp(), String(error.prefix(300)), etag, etag, lastModified, lastModified, url, name])
        }
    }

    // MARK: VPN

    struct VPN: Equatable { var on = false; var selected: Int64? }

    func vpn() throws -> VPN {
        try queue.read { db in
            let r = try Row.fetchOne(db, sql: "SELECT vpn_on, selected_tunnel_id FROM settings WHERE id = 1")
            return VPN(on: (r?["vpn_on"] as Int?) == 1, selected: r?["selected_tunnel_id"])
        }
    }

    func setVPN(on: Bool) throws {
        try queue.write { try $0.execute(sql: "UPDATE settings SET vpn_on = ? WHERE id = 1", arguments: [on ? 1 : 0]) }
    }

    struct KillSwitch: Equatable { var on = false; var lan = true }

    func killSwitch() throws -> KillSwitch {
        try queue.read { db in
            let r = try Row.fetchOne(db, sql: "SELECT kill_switch, kill_switch_lan FROM settings WHERE id = 1")
            return KillSwitch(on: (r?["kill_switch"] as Int?) == 1, lan: (r?["kill_switch_lan"] as Int?) != 0)
        }
    }

    func setKillSwitch(on: Bool? = nil, lan: Bool? = nil) throws {
        try queue.write { db in
            if let on { try db.execute(sql: "UPDATE settings SET kill_switch = ? WHERE id = 1", arguments: [on ? 1 : 0]) }
            if let lan { try db.execute(sql: "UPDATE settings SET kill_switch_lan = ? WHERE id = 1", arguments: [lan ? 1 : 0]) }
        }
    }

    func bootstrap() throws -> String {
        try queue.read { try String.fetchOne($0, sql: "SELECT bootstrap FROM settings WHERE id = 1") ?? "" }
    }

    func setBootstrap(_ value: String) throws {
        try queue.write { try $0.execute(sql: "UPDATE settings SET bootstrap = ? WHERE id = 1", arguments: [value]) }
    }

    func setSelected(_ id: Int64?) throws {
        try queue.write { try $0.execute(sql: "UPDATE settings SET selected_tunnel_id = ? WHERE id = 1", arguments: [id]) }
    }

    /// Why a tunnel can't be removed now: it is selected while the VPN is on.
    func selectedGuard(_ ids: [Int64]) throws {
        let v = try vpn()
        if v.on, let s = v.selected, ids.contains(s) {
            throw StoreError("This server is selected and connected: select another server or disconnect first.")
        }
    }
}
