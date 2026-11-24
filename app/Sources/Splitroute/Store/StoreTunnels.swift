import Foundation
import GRDB

// Tunnels and subscriptions. The database holds metadata only; what a tunnel runs (an OpenVPN profile, or a link's
// options) is a 0600 file (Secrets), checked against `sha` before it is sent to the service.

extension Store {
    private static let tunnelColumns = "id, name, kind, profile_sha256, remotes, needs_auth, key_encrypted, auto_connect, subscription_id, warning, server_override"

    private static func tunnel(_ r: Row) -> StoreTunnel {
        let remotes: String = r["remotes"]
        return StoreTunnel(id: r["id"], name: r["name"], kind: r["kind"], sha: r["profile_sha256"],
                           remotes: remotes.isEmpty ? [] : remotes.components(separatedBy: "\n"),
                           needsAuth: (r["needs_auth"] as Int) == 1, keyEncrypted: (r["key_encrypted"] as Int) == 1,
                           autoConnect: (r["auto_connect"] as Int) == 1, subscriptionID: r["subscription_id"], warning: r["warning"],
                           serverOverride: r["server_override"])
    }

    func tunnels() throws -> [StoreTunnel] {
        try queue.read { db in try Row.fetchAll(db, sql: "SELECT \(Store.tunnelColumns) FROM tunnels ORDER BY position, id").map(Store.tunnel) }
    }

    func subscriptions() throws -> [StoreSubscription] {
        try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT id, name, last_error, updated_at FROM subscriptions ORDER BY id").map {
                StoreSubscription(id: $0["id"], name: $0["name"], lastError: $0["last_error"], updatedAt: $0["updated_at"])
            }
        }
    }

    /// Makes a display name fit the schema: no control characters, no edge spaces, at most 64 bytes without cutting a
    /// character, never empty.
    static func cleanName(_ s: String, fallback: String = "Server") -> String {
        let mapped = String(s.unicodeScalars.map { u -> Character in
            (u.value < 0x20 || u.value == 0x7f || u.value == 0x200E || u.value == 0x200F || u.value == 0xFEFF) ? " " : Character(u)
        })
        var out = mapped.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        while out.utf8.count > 64 { out.removeLast() }
        out = out.trimmingCharacters(in: .whitespaces)
        return out.isEmpty ? fallback : out
    }

    /// `base`, or `base 2`, `base 3` ... when a name in `table` already has it (names compare without case).
    private static func uniqueName(_ db: Database, _ table: String, _ base: String) throws -> String {
        for i in 1...(maxTunnels + 1) {
            var name = base
            if i > 1 {
                let suffix = " \(i)"
                var b = base
                while b.utf8.count > 64 - suffix.utf8.count { b.removeLast() }
                name = b + suffix
            }
            if try Int.fetchOne(db, sql: "SELECT count(*) FROM \(table) WHERE name = ?", arguments: [name]) == 0 { return name }
        }
        throw StoreError("Too many servers with the same name.")
    }

    private static func insert(_ db: Database, _ t: StoreTunnel, now: String) throws -> Int64 {
        guard t.sha.count == 64 else { throw StoreError("A server needs its content's SHA-256.") }
        try db.execute(sql: """
            INSERT INTO tunnels (name, kind, profile_sha256, remotes, needs_auth, key_encrypted, scripts, auto_connect, subscription_id, warning, position, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, '', ?, ?, ?, (SELECT coalesce(max(position), -1) + 1 FROM tunnels), ?, ?)
            """, arguments: [t.name, t.kind, t.sha, t.remotes.joined(separator: "\n"), t.needsAuth ? 1 : 0, t.keyEncrypted ? 1 : 0,
                             t.autoConnect ? 1 : 0, t.subscriptionID, t.warning, now, now])
        return db.lastInsertedRowID
    }

    /// Stores tunnels in one transaction: all of them or none. A name that is taken gets a number. With `subscription`
    /// they join a new group of that name (made unique the same way). Each returned tunnel has its ID and final name.
    func addTunnels(_ ts: [StoreTunnel], subscription: String? = nil) throws -> (subscription: StoreSubscription?, tunnels: [StoreTunnel]) {
        try queue.write { db in
            let n = try Int.fetchOne(db, sql: "SELECT count(*) FROM tunnels") ?? 0
            guard n + ts.count <= Store.maxTunnels else { throw StoreError("At most \(Store.maxTunnels) servers; remove some first.") }
            let now = Store.stamp()
            var sub: StoreSubscription?
            if let name = subscription {
                let unique = try Store.uniqueName(db, "subscriptions", Store.cleanName(name, fallback: "Subscription"))
                try db.execute(sql: "INSERT INTO subscriptions (name, created_at, updated_at) VALUES (?, ?, ?)", arguments: [unique, now, now])
                sub = StoreSubscription(id: db.lastInsertedRowID, name: unique, lastError: "", updatedAt: now)
            }
            var out: [StoreTunnel] = []
            for var t in ts {
                t.name = try Store.uniqueName(db, "tunnels", Store.cleanName(t.name))
                t.subscriptionID = sub?.id
                t.id = try Store.insert(db, t, now: now)
                out.append(t)
            }
            return (sub, out)
        }
    }

    func listsUsing(tunnel id: Int64) throws -> [String] {
        try queue.read { try Store.listsUsing($0, id) }
    }

    private static func listsUsing(_ db: Database, _ id: Int64) throws -> [String] {
        var names = try String.fetchAll(db, sql: "SELECT name FROM lists WHERE tunnel_id = ? ORDER BY position", arguments: [id])
        if try Int.fetchOne(db, sql: "SELECT 1 FROM settings WHERE final_tunnel_id = ?", arguments: [id]) != nil { names.append("Default Route") }
        return names
    }

    static func inUse(_ lists: [String]) -> StoreError {
        StoreError("This server is used by the lists \(lists.joined(separator: ", ")); choose another server for them first.")
    }

    func removeTunnel(_ id: Int64) throws {
        try queue.write { db in
            let using = try Store.listsUsing(db, id)
            guard using.isEmpty else { throw Store.inUse(using) }
            try db.execute(sql: "DELETE FROM tunnels WHERE id = ?", arguments: [id])
        }
    }

    /// Sets or clears (empty) the server an OpenVPN tunnel connects to in place of its profile's.
    func setServerOverride(_ id: Int64, _ spec: String) throws {
        try queue.write { try $0.execute(sql: "UPDATE tunnels SET server_override = ?, updated_at = ? WHERE id = ?", arguments: [spec, Store.stamp(), id]) }
    }

    func renameTunnel(_ id: Int64, to name: String) throws {
        let clean = Store.cleanName(name)
        do {
            try queue.write { try $0.execute(sql: "UPDATE tunnels SET name = ?, updated_at = ? WHERE id = ?", arguments: [clean, Store.stamp(), id]) }
        } catch let e as DatabaseError where e.extendedResultCode == .SQLITE_CONSTRAINT_UNIQUE {
            throw StoreError("A server with that name already exists.")
        }
    }

    func setAutoConnect(_ id: Int64, _ on: Bool) throws {
        try queue.write { try $0.execute(sql: "UPDATE tunnels SET auto_connect = ?, updated_at = ? WHERE id = ?", arguments: [on ? 1 : 0, Store.stamp(), id]) }
    }

    // MARK: Subscriptions

    func listsUsing(subscription id: Int64) throws -> [String] {
        try queue.read { try Store.listsUsingSubscription($0, id) }
    }

    private static func listsUsingSubscription(_ db: Database, _ id: Int64) throws -> [String] {
        try String.fetchAll(db, sql: """
            SELECT DISTINCT l.name FROM lists l JOIN tunnels t ON l.tunnel_id = t.id WHERE t.subscription_id = ? ORDER BY l.position
            """, arguments: [id])
            + (try Int.fetchOne(db, sql: "SELECT 1 FROM settings s JOIN tunnels t ON s.final_tunnel_id = t.id WHERE t.subscription_id = ?", arguments: [id]) != nil
               ? ["Default Route"] : [])
    }

    /// Deletes a subscription and its tunnels in one transaction. Refused while a list uses one of them.
    func removeSubscription(_ id: Int64) throws {
        try queue.write { db in
            let using = try Store.listsUsingSubscription(db, id)
            guard using.isEmpty else {
                throw StoreError("A server of this subscription is used by the lists \(using.joined(separator: ", ")); choose another server for them first.")
            }
            try db.execute(sql: "DELETE FROM tunnels WHERE subscription_id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM subscriptions WHERE id = ?", arguments: [id])
            guard db.changesCount > 0 else { throw StoreError("No such subscription.") }
        }
    }

    func renameSubscription(_ id: Int64, to name: String) throws {
        do {
            try queue.write {
                try $0.execute(sql: "UPDATE subscriptions SET name = ? WHERE id = ?", arguments: [Store.cleanName(name, fallback: "Subscription"), id])
                guard $0.changesCount > 0 else { throw StoreError("No such subscription.") }
            }
        } catch let e as DatabaseError where e.extendedResultCode == .SQLITE_CONSTRAINT_UNIQUE {
            throw StoreError("A subscription with that name already exists.")
        }
    }

    /// Why the last update failed. The text never holds the address.
    func setSubscriptionError(_ id: Int64, _ message: String) throws {
        try queue.write { try $0.execute(sql: "UPDATE subscriptions SET last_error = ? WHERE id = ?", arguments: [String(message.prefix(300)), id]) }
    }

    /// The change an update makes to a subscription's tunnels. `update` holds tunnels with their IDs; only the hash, the
    /// remotes and the warning change, so lists and the selected tunnel keep pointing at them.
    struct Sync {
        var add: [StoreTunnel] = []
        var update: [StoreTunnel] = []
        var remove: [Int64] = []
    }

    /// Applies a sync in one transaction and marks the subscription updated now. A tunnel a list uses is never removed:
    /// the whole sync is refused and nothing changes. `files` runs before the commit with the added tunnels (IDs and
    /// final names set); if it throws, nothing is stored.
    func sync(subscription id: Int64, _ sy: Sync, files: ([StoreTunnel]) throws -> Void) throws -> [StoreTunnel] {
        try queue.write { db in
            guard try Int.fetchOne(db, sql: "SELECT count(*) FROM subscriptions WHERE id = ?", arguments: [id]) == 1 else { throw StoreError("No such subscription.") }
            let n = try Int.fetchOne(db, sql: "SELECT count(*) FROM tunnels") ?? 0
            guard n + sy.add.count - sy.remove.count <= Store.maxTunnels else { throw StoreError("At most \(Store.maxTunnels) servers; remove some first.") }
            let now = Store.stamp()
            for tid in sy.remove {
                let using = try Store.listsUsing(db, tid)
                guard using.isEmpty else { throw Store.inUse(using) }
                try db.execute(sql: "DELETE FROM tunnels WHERE id = ? AND subscription_id = ?", arguments: [tid, id])
            }
            for t in sy.update {
                try db.execute(sql: "UPDATE tunnels SET profile_sha256 = ?, remotes = ?, warning = ?, updated_at = ? WHERE id = ? AND subscription_id = ?",
                               arguments: [t.sha, t.remotes.joined(separator: "\n"), t.warning, now, t.id, id])
            }
            var added: [StoreTunnel] = []
            for var t in sy.add {
                t.name = try Store.uniqueName(db, "tunnels", Store.cleanName(t.name))
                t.subscriptionID = id
                t.id = try Store.insert(db, t, now: now)
                added.append(t)
            }
            try db.execute(sql: "UPDATE subscriptions SET updated_at = ?, last_error = '' WHERE id = ?", arguments: [now, id])
            try files(added)
            return added
        }
    }
}
