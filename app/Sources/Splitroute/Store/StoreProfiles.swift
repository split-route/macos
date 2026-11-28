import Foundation
import GRDB

// Routing profiles: each has its own lists and its own default route; one is active (`settings.active_profile_id`) and is
// what `config()` and every list query by name see. Switching changes what the service runs; nothing is copied or deleted.

extension Store {
    static let maxProfiles = 32

    /// A profile's name, tidied the way a server's is; refused when empty or already taken (ignoring case) by another profile.
    private static func profileName(_ db: Database, _ raw: String, excluding id: Int64? = nil) throws -> String {
        let name = cleanName(raw, fallback: "")
        guard !name.isEmpty else { throw StoreError("A profile needs a name.") }
        let taken = try Int64.fetchAll(db, sql: "SELECT id FROM profiles WHERE lower(name) = lower(?)", arguments: [name])
        if taken.contains(where: { $0 != id }) { throw StoreError("A profile named \"\(name)\" already exists.") }
        return name
    }

    /// Makes `name` the profile the app shows and the service runs.
    func setActiveProfile(_ name: String) throws {
        try queue.write { db in
            guard let id = try Int64.fetchOne(db, sql: "SELECT id FROM profiles WHERE name = ?", arguments: [name]) else {
                throw StoreError("No profile named \"\(name)\".")
            }
            try db.execute(sql: "UPDATE settings SET active_profile_id = ? WHERE id = 1", arguments: [id])
        }
    }

    /// Adds a profile with no lists (its default route is the active server) and makes it the active one. Returns the name
    /// it was given.
    @discardableResult
    func createProfile(_ raw: String) throws -> String {
        try queue.write { db in
            guard try Int.fetchOne(db, sql: "SELECT count(*) FROM profiles") ?? 0 < Store.maxProfiles else {
                throw StoreError("At most \(Store.maxProfiles) profiles; delete one first.")
            }
            let name = try Store.profileName(db, raw)
            try db.execute(sql: "INSERT INTO profiles (name, position, created_at) VALUES (?, (SELECT coalesce(max(position), -1) + 1 FROM profiles), ?)",
                           arguments: [name, Store.stamp()])
            try db.execute(sql: "UPDATE settings SET active_profile_id = ? WHERE id = 1", arguments: [db.lastInsertedRowID])
            return name
        }
    }

    func renameProfile(_ old: String, to raw: String) throws {
        try queue.write { db in
            guard let id = try Int64.fetchOne(db, sql: "SELECT id FROM profiles WHERE name = ?", arguments: [old]) else {
                throw StoreError("No profile named \"\(old)\".")
            }
            let name = try Store.profileName(db, raw, excluding: id)
            try db.execute(sql: "UPDATE profiles SET name = ? WHERE id = ?", arguments: [name, id])
        }
    }

    /// Deletes a profile with its lists (and their entries). The last profile can't be deleted; deleting the active one makes
    /// the first of the others active. Returns the profile that is active afterwards.
    @discardableResult
    func deleteProfile(_ name: String) throws -> String {
        try queue.write { db in
            guard try Int.fetchOne(db, sql: "SELECT count(*) FROM profiles") ?? 0 > 1 else {
                throw StoreError("This is the only profile; it can't be deleted.")
            }
            guard let id = try Int64.fetchOne(db, sql: "SELECT id FROM profiles WHERE name = ?", arguments: [name]) else {
                throw StoreError("No profile named \"\(name)\".")
            }
            if try Int64.fetchOne(db, sql: "SELECT \(Store.activeProfile)") == id {
                try db.execute(sql: "UPDATE settings SET active_profile_id = (SELECT id FROM profiles WHERE id <> ? ORDER BY position, id LIMIT 1) WHERE id = 1", arguments: [id])
            }
            try db.execute(sql: "DELETE FROM profiles WHERE id = ?", arguments: [id])
            return try String.fetchOne(db, sql: "SELECT name FROM profiles WHERE id = \(Store.activeProfile)") ?? "Default"
        }
    }
}
