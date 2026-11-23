import Foundation
import GRDB

/// Moves what versions before 0.3 kept in the service (root-owned) to the app. The database is copied whole (the schema
/// is the same, so lists, imports, tunnels, subscriptions and the VPN switch carry over with their IDs); the root-only
/// files (profiles, link options, subscription addresses) come from the service once, through `legacy_export`. The old
/// files are left where they are: a failed move can run again, and a downgrade still finds its state.
enum LegacyMigration {
    static let oldDatabase = "/var/db/splitroute/splitroute.db"
    static let oldLists = "/var/db/splitroute/lists"
    static let pending = "daemon:pending"
    static let done = "daemon"

    /// Copies the service's database to the app's when the app has none yet. A consistent copy (SQLite's backup), made
    /// beside the target and moved into place, so a crash never leaves half a database.
    static func copyDatabase(to files: AppFiles, from old: String = oldDatabase, lists: String = oldLists) throws {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: files.databasePath), fm.isReadableFile(atPath: old) else { return }
        try fm.createDirectory(at: files.root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let tmp = files.databasePath + ".migrating"
        try? fm.removeItem(atPath: tmp)
        var ro = Configuration()
        ro.readonly = true
        ro.busyMode = .timeout(5)
        do {
            let src = try DatabaseQueue(path: old, configuration: ro)
            let version = try src.read { try Int.fetchOne($0, sql: "PRAGMA user_version") ?? 0 }
            guard version <= Schema.migrations.count else {
                throw StoreError("The service's database is from a newer Splitroute (schema \(version)). Update the app.")
            }
            let dst = try DatabaseQueue(path: tmp)
            try src.backup(to: dst)
            try dst.write { try $0.execute(sql: "UPDATE settings SET migrated_from = ?", arguments: [pending]) }
        } catch let e as DatabaseError where e.resultCode == .SQLITE_NOTADB {
            try? fm.removeItem(atPath: tmp)
            return // not a database: start fresh
        } catch {
            // Busy, locked, newer, or a transient failure: the app does not open this launch, and no default database is
            // made, so the copy is tried again at the next one. Starting fresh here would lose the user's settings for good.
            try? fm.removeItem(atPath: tmp)
            throw error
        }
        try fm.moveItem(atPath: tmp, toPath: files.databasePath)
        // Release lists the service had downloaded: the app has them at once, even offline.
        for f in (try? fm.contentsOfDirectory(atPath: lists)) ?? [] where f.hasSuffix(".list") {
            if let d = fm.contents(atPath: lists + "/" + f) { try? files.writeRelease(String(f.dropLast(5)), d) }
        }
    }

    /// Writes what the service exported next to the database. A tunnel whose file is missing or doesn't match its stored
    /// hash is left without one: it shows as failed ("import it again") instead of running something unchecked.
    static func importSecrets(_ legacy: WireLegacy, store: Store, files: AppFiles) throws {
        for t in try store.tunnels() {
            guard let x = legacy.tunnels[String(t.id)] else { continue }
            let text = t.isOpenVPN ? x.profile : x.options
            guard let data = text.map({ Data($0.utf8) }), AppFiles.sha256(data) == t.sha else { continue }
            try? files.writeTunnelSource(t, data) // one that can't be written shows as failed; the others still move
        }
        let known = Set(try store.subscriptions().map(\.id))
        for (key, s) in legacy.subscriptions {
            guard let id = Int64(key), known.contains(id) else { continue }
            try files.writeSubscriptionURL(id, s.url)
            files.saveUsage(id, s.usage)
        }
        try store.setMigratedFrom(done)
    }
}

extension Store {
    func migratedFrom() throws -> String {
        try queue.read { try String.fetchOne($0, sql: "SELECT migrated_from FROM settings WHERE id = 1") ?? "" }
    }

    func setMigratedFrom(_ s: String) throws {
        try queue.write { try $0.execute(sql: "UPDATE settings SET migrated_from = ? WHERE id = 1", arguments: [s]) }
    }
}

extension AppModel {
    /// After a database was copied from the service: asks it for the files only root could read. Retried every poll
    /// until it answers (an older service says "unknown command" until it restarts).
    func migrateLegacySecrets() async {
        guard let store, (try? store.migratedFrom()) == LegacyMigration.pending else { return }
        do {
            let legacy = try await Daemon.legacyExport()
            try LegacyMigration.importSecrets(legacy, store: store, files: files)
            link?.markDirty()
            reloadLocal()
        } catch {
            errors["migration"] = "Moving your tunnels from the service: \(error.localizedDescription)"
        }
    }
}
