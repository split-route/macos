import GRDB
import XCTest
@testable import Splitroute

final class StoreTests: XCTestCase {
    var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("sr-\(UUID().uuidString)")
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func newStore() throws -> Store { try Store(path: dir.appendingPathComponent("db.sqlite").path) }

    func tunnel(_ name: String, kind: String = "vless", sha: String = String(repeating: "a", count: 64)) -> StoreTunnel {
        StoreTunnel(id: 0, name: name, kind: kind, sha: sha, remotes: ["example.com:443"])
    }

    // MARK: Schema and migrations

    func testNewDatabaseHasTheDefaultsAtTheLatestSchema() throws {
        let s = try newStore()
        XCTAssertEqual(try s.config().lists.map(\.name), ["ir-cidr"])
        XCTAssertEqual(try s.queue.read { try Int.fetchOne($0, sql: "PRAGMA user_version") }, Schema.migrations.count)
        XCTAssertEqual(try s.vpn(), Store.VPN(on: false, selected: nil))
    }

    func testANewerSchemaIsRefusedAndLeftAlone() throws {
        _ = try newStore()
        let path = dir.appendingPathComponent("db.sqlite").path
        try DatabaseQueue(path: path).write { try $0.execute(sql: "PRAGMA user_version = \(Schema.migrations.count + 1)") }
        XCTAssertThrowsError(try Store(path: path)) { XCTAssertTrue("\($0)".contains("newer")) }
        XCTAssertEqual(try DatabaseQueue(path: path).read { try Int.fetchOne($0, sql: "PRAGMA user_version") }, Schema.migrations.count + 1)
    }

    /// A database the daemon wrote at schema 3 (before subscriptions) upgrades in place, keeping its rows, and the rebuild
    /// migrations leave a copy to go back to.
    func testUpgradingAnOldDatabaseKeepsEverythingAndBacksUp() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("db.sqlite").path
        let q = try DatabaseQueue(path: path)
        try q.write { db in
            for m in Schema.migrations.prefix(3) { try db.execute(sql: m) }
            try db.execute(sql: "PRAGMA user_version = 3")
            try db.execute(sql: "INSERT INTO settings (id, created_at) VALUES (1, 'x')")
            try db.execute(sql: "INSERT INTO lists (name, source, action, position, created_at, updated_at) VALUES ('mine', 'custom', 'vpn', 0, 'x', 'x')")
            try db.execute(sql: "INSERT INTO tunnels (name, profile_sha256, position, created_at, updated_at) VALUES ('Work', '\(String(repeating: "b", count: 64))', 0, 'x', 'x')")
            try db.execute(sql: "INSERT INTO entries (list_id, position, kind, value) VALUES (1, 0, 'domain_suffix', 'example.com')")
            try db.execute(sql: "INSERT INTO lists (name, source, action, position, created_at, updated_at) VALUES ('feed', 'import', 'block', 1, 'x', 'x')")
            try db.execute(sql: "INSERT INTO import_sources (list_id, url) VALUES (2, 'https://example.com/x')")
            try db.execute(sql: "INSERT INTO entries (list_id, position, kind, value) VALUES (2, 0, 'domain_suffix', 'ads.example.net')")
        }
        try q.close()
        let s = try Store(path: path)
        XCTAssertEqual(try s.config().lists.first?.action, .tunnel, "the old vpn action reads as tunnel")
        XCTAssertEqual(try s.tunnels().map(\.name), ["Work"])
        // Foreign keys were off during the rebuild: dropping the old lists table must not have cascaded to the entries.
        XCTAssertEqual(try s.queue.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM entries") }, 2)
        XCTAssertEqual(try s.importLines("feed"), ["ads.example.net"])
        XCTAssertEqual(try s.queue.read { try Int.fetchOne($0, sql: "PRAGMA foreign_keys") }, 1, "turned back on afterwards")
        XCTAssertEqual(try s.queue.read { try Int.fetchOne($0, sql: "SELECT seq FROM sqlite_sequence WHERE name = 'tunnels'") }, 1, "ids are never reused")
        let backup = try DatabaseQueue(path: path + ".v3")
        XCTAssertEqual(try backup.read { try Int.fetchOne($0, sql: "PRAGMA user_version") }, 3, "the copy is the database as it was")
        XCTAssertEqual(try backup.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM entries") }, 2)
        XCTAssertEqual(try s.queue.read { try Int.fetchOne($0, sql: "PRAGMA user_version") }, Schema.migrations.count)
    }

    // MARK: Lists

    func testListEditsRoundTripThroughTheDatabase() throws {
        let s = try newStore()
        try s.update { try $0.creating("Work", .block) }
        try s.update { try $0.settingEntries("Work", ["# the office", "example.com", "full:a.example.com", "AS13335", "8.8.8.0/24", "1.1.1.1", "# trailing"]).0 }
        try s.update { try $0.moving("Work", to: 0) }
        let c = try s.config()
        XCTAssertEqual(c.lists.map(\.name), ["Work", "ir-cidr"])
        XCTAssertEqual(c.lists[0].entries, ["# the office", "example.com", "full:a.example.com", "AS13335", "8.8.8.0/24", "1.1.1.1", "# trailing"])
        let (c2, ed) = try c.addingEntries("Work", ["example.com", "mail.example.com"])
        XCTAssertEqual(ed.added, 1)
        XCTAssertEqual(ed.duplicates, 1)
        let (c3, ed3) = try c2.removingEntries("Work", ["example.com", "nope.example.com"])
        XCTAssertEqual(ed3.removed, 1)
        XCTAssertEqual(ed3.notFound, ["nope.example.com"])
        XCTAssertFalse(c3.lists[0].entries.contains("example.com"))
        XCTAssertFalse(c3.lists[0].entries.contains("# the office"), "a note goes with its entry")
    }

    /// "No Action" keeps the list (and its entries) without applying it: the lists table accepts it and the rows survive.
    func testAListWithNoActionIsKeptWithItsEntries() throws {
        let s = try newStore()
        try s.update { try $0.creating("Work", .block) }
        try s.update { try $0.settingEntries("Work", ["example.com"]).0 }
        try s.update { try $0.settingAction("Work", .none, tunnel: nil) }
        let l = try s.config().lists.first { $0.name == "Work" }
        XCTAssertEqual(l?.action, Action.none) // not .none: that reads as Optional.none
        XCTAssertEqual(l?.entries, ["example.com"])
    }

    /// A custom list or import can carry a one-line description; a ready-made list cannot (its text is the catalog's).
    func testAListDescriptionRoundTripsAndIsChecked() throws {
        let s = try newStore()
        try s.update { try $0.creating("Work", .block, description: "Sites for the office") }
        XCTAssertEqual(try s.config().lists.first { $0.name == "Work" }?.description, "Sites for the office")
        try s.update { try $0.settingDescription("Work", "") }
        XCTAssertNil(try s.config().lists.first { $0.name == "Work" }?.description, "empty clears it")
        XCTAssertThrowsError(try s.update { try $0.settingDescription("Work", String(repeating: "x", count: 121)) })
        XCTAssertThrowsError(try s.update { try $0.settingDescription("Work", "two\nlines") })
        XCTAssertThrowsError(try s.update { try $0.settingDescription("ir-cidr", "mine") }, "a ready-made list has the catalog's")
        try s.update { try $0.importing("Feed", .block, url: "https://example.com/a.txt", description: "A feed") }
        XCTAssertEqual(try s.config().lists.first { $0.name == "Feed" }?.description, "A feed")
    }

    func testAnImportsAddressCanBeChangedOnlyToAnHTTPSOne() throws {
        let s = try newStore()
        try s.update { try $0.importing("Feed", .block, url: "https://example.com/a.txt") }
        XCTAssertThrowsError(try s.update { try $0.settingImportURL("Feed", to: "http://example.com/a.txt") })
        XCTAssertThrowsError(try s.update { try $0.settingImportURL("ir-cidr", to: "https://example.com/b.txt") }, "not an import")
        try s.update { try $0.settingImportURL("Feed", to: "https://example.com/b.txt") }
        XCTAssertEqual(try s.config().lists.first { $0.name == "Feed" }?.importSource?.url, "https://example.com/b.txt")
    }

    /// Renaming an import keeps its downloaded entries (they live only in the database).
    func testRenamingAnImportKeepsItsEntries() throws {
        let s = try newStore()
        try s.update { try $0.importing("Feed", .block, url: "https://example.com/a.txt") }
        _ = try s.saveDownload(name: "Feed", url: "https://example.com/a.txt", lines: ["example.com", "8.8.8.0/24"], etag: "", lastModified: "", sha256: "x", skipped: 0)
        try s.renameList("Feed", to: "News")
        XCTAssertEqual(try s.importLines("News"), ["example.com", "8.8.8.0/24"])
        XCTAssertEqual(try s.config().lists.map(\.name).contains("Feed"), false)
        XCTAssertThrowsError(try s.renameList("News", to: "ir-cidr"), "a taken name")
    }

    /// Refusing QUIC is on by default and survives a round trip.
    func testBlockQUICDefaultsOnAndRoundTrips() throws {
        let s = try newStore()
        XCTAssertTrue(try s.config().blockQUIC)
        try s.update { var c = $0; c.blockQUIC = false; return c }
        XCTAssertFalse(try s.config().blockQUIC)
        try s.update { var c = $0; c.blockQUIC = true; return c }
        XCTAssertTrue(try s.config().blockQUIC)
    }

    /// A proxy server that is not the active one is loaded but idle (the service says disconnected); it still carries a
    /// list's traffic, so it is not "down". An OpenVPN server that says disconnected is.
    func testWhichServersCountAsUp() {
        func server(_ protocolName: String, _ state: TunnelState) -> Tunnel {
            Tunnel(name: "x", protocolName: protocolName, group: nil, warning: nil, transport: nil, remotes: nil, needsAuth: false,
                   keyEncrypted: false, autoConnect: false, state: state)
        }
        XCTAssertTrue(AppModel.isUp(server("vless", .disconnected), engineRunning: true))
        XCTAssertFalse(AppModel.isUp(server("vless", .disconnected), engineRunning: false), "no engine, nothing carries traffic")
        XCTAssertFalse(AppModel.isUp(server("openvpn", .disconnected), engineRunning: true))
        XCTAssertTrue(AppModel.isUp(server("openvpn", .connected), engineRunning: true))
        XCTAssertTrue(AppModel.isUp(server("vless", .ready), engineRunning: true))
        for s in [TunnelState.failed, .needsAuth, .connecting] { XCTAssertFalse(AppModel.isUp(server("vless", s), engineRunning: true)) }
    }

    func testListRulesRefuseWhatTheyMust() throws {
        let c = Config.initial
        XCTAssertThrowsError(try c.enablingRelease("ir-cidr", .direct)) // twice
        XCTAssertThrowsError(try c.enablingRelease("Bad Name", .direct))
        XCTAssertThrowsError(try c.importing("feed", .block, url: "http://example.com/x")) // not https
        XCTAssertThrowsError(try c.importing("feed", .block, url: "https://user:pw@example.com/x"))
        XCTAssertThrowsError(try c.renaming("ir-cidr", to: "other")) // a release list
        XCTAssertThrowsError(try c.settingAction("ir-cidr", .block, tunnel: "Work")) // only a tunnel list names a tunnel
        XCTAssertThrowsError(try c.creating("x", .direct).addingEntries("ir-cidr", ["a.com"])) // not custom
        XCTAssertThrowsError(try c.moving("ir-cidr", to: 5))
    }

    func testAListMustNameATunnelThatExists() throws {
        let s = try newStore()
        XCTAssertThrowsError(try s.update { try $0.settingAction("ir-cidr", .tunnel, tunnel: "Ghost") })
        let t = try s.addTunnels([tunnel("Work")]).tunnels[0]
        try s.update { try $0.settingAction("ir-cidr", .tunnel, tunnel: "Work") }
        XCTAssertEqual(try s.listsUsing(tunnel: t.id), ["ir-cidr"])
        XCTAssertThrowsError(try s.removeTunnel(t.id)) { XCTAssertTrue("\($0)".contains("ir-cidr")) }
        XCTAssertEqual(try s.tunnels().count, 1, "a refused removal changes nothing")
    }

    /// The final route (everything no list matches) defaults to the selected tunnel, survives a round trip, refuses
    /// a missing tunnel or "no action", and keeps the tunnel it names from being removed.
    func testTheFinalRouteRoundTripsAndPinsItsTunnel() throws {
        let s = try newStore()
        var c = try s.config()
        XCTAssertEqual(c.finalAction, .tunnel)
        XCTAssertNil(c.finalTunnel)
        try s.update { try $0.settingFinal(.direct, tunnel: nil) }
        c = try s.config()
        XCTAssertEqual(c.finalAction, .direct)
        XCTAssertThrowsError(try s.update { try $0.settingFinal(.none, tunnel: nil) })
        XCTAssertThrowsError(try s.update { try $0.settingFinal(.direct, tunnel: "Work") }, "a tunnel only with the tunnel action")
        XCTAssertThrowsError(try s.update { try $0.settingFinal(.tunnel, tunnel: "Ghost") })
        let t = try s.addTunnels([tunnel("Work")]).tunnels[0]
        try s.update { try $0.settingFinal(.tunnel, tunnel: "Work") }
        c = try s.config()
        XCTAssertEqual(c.finalTunnel, "Work")
        XCTAssertEqual(try s.listsUsing(tunnel: t.id), ["Default Route"])
        XCTAssertThrowsError(try s.removeTunnel(t.id)) { XCTAssertTrue("\($0)".contains("Default Route")) }
        try s.update { try $0.settingFinal(.tunnel, tunnel: nil) }
        try s.removeTunnel(t.id)
    }

    func testAnImportKeepsItsEntriesUntilItsAddressChanges() throws {
        let s = try newStore()
        try s.update { try $0.importing("feed", .block, url: "https://example.com/a.txt") }
        XCTAssertTrue(try s.saveDownload(name: "feed", url: "https://example.com/a.txt", lines: ["ads.example.net", "full:x.example.net"],
                                         etag: "e1", lastModified: "", sha256: "s1", skipped: 2))
        XCTAssertEqual(try s.importLines("feed"), ["ads.example.net", "full:x.example.net"])
        try s.update { try $0.settingAction("feed", .direct, tunnel: nil) }
        XCTAssertEqual(try s.imports()[0].entries, 2, "an unrelated edit keeps the download")
        // The address changed while a download ran: it is discarded.
        try s.update { c in
            var c = c
            c.lists[c.lists.firstIndex { $0.name == "feed" }!].importSource = ImportSource(url: "https://example.com/b.txt", refreshHours: nil)
            return c
        }
        XCTAssertEqual(try s.imports()[0].entries, 0, "entries from another source would mislead")
        XCTAssertFalse(try s.saveDownload(name: "feed", url: "https://example.com/a.txt", lines: ["old.example.net"], etag: "", lastModified: "", sha256: "", skipped: 0))
        XCTAssertTrue(try s.imports()[0].isDue(), "never downloaded")
    }

    func testEntryKindsFromCanonicalLines() {
        XCTAssertEqual(Entries.kind("full:a.example.com"), "domain")
        XCTAssertEqual(Entries.kind("AS13335"), "asn")
        XCTAssertEqual(Entries.kind("8.8.8.0/24"), "cidr")
        XCTAssertEqual(Entries.kind("2400:cb00::/32"), "cidr")
        XCTAssertEqual(Entries.kind("example.com"), "domain_suffix")
        XCTAssertEqual(Entries.kind("ASUS.com"), "domain_suffix", "a name that starts with AS is not an AS number")
        for line in ["full:a.example.com", "AS13335", "8.8.8.0/24", "example.com"] {
            XCTAssertEqual(Entries.text(kind: Entries.kind(line), value: Entries.value(line)), line)
        }
    }

    // MARK: Tunnels and subscriptions

    func testNamesAreMadeUniqueAndFitTheSchema() throws {
        let s = try newStore()
        let added = try s.addTunnels([tunnel("Node"), tunnel("node"), tunnel("  Node\u{200E} "), tunnel(String(repeating: "é", count: 80))]).tunnels
        XCTAssertEqual(added.map(\.name).prefix(3), ["Node", "node 2", "Node 3"])
        XCTAssertLessThanOrEqual(added[3].name.utf8.count, 64)
        XCTAssertEqual(Store.cleanName("\u{0}\u{7}"), "Server")
    }

    func testRemovingASubscriptionRemovesItsTunnelsUnlessAListUsesOne() throws {
        let s = try newStore()
        let (sub, ts) = try s.addTunnels([tunnel("A"), tunnel("B")], subscription: "Provider")
        try s.update { try $0.settingAction("ir-cidr", .tunnel, tunnel: "B") }
        XCTAssertThrowsError(try s.removeSubscription(sub!.id))
        XCTAssertEqual(try s.tunnels().count, 2, "nothing changed")
        try s.update { try $0.settingAction("ir-cidr", .direct, tunnel: nil) }
        try s.removeSubscription(sub!.id)
        XCTAssertEqual(try s.tunnels().count, 0)
        XCTAssertEqual(try s.subscriptions().count, 0)
        _ = ts
    }

    func testTheSelectedTunnelCannotBeRemovedWhileTheVPNIsOn() throws {
        let s = try newStore()
        let t = try s.addTunnels([tunnel("A")]).tunnels[0]
        try s.setSelected(t.id)
        XCTAssertNoThrow(try s.selectedGuard([t.id])) // the VPN is off
        try s.setVPN(on: true)
        XCTAssertThrowsError(try s.selectedGuard([t.id]))
    }

    func testSyncKeepsIdentitiesAndRefusesToDropATunnelAListUses() throws {
        let s = try newStore()
        let (sub, ts) = try s.addTunnels([tunnel("A"), tunnel("B")], subscription: "P")
        try s.update { try $0.settingAction("ir-cidr", .tunnel, tunnel: "B") }
        var sy = Store.Sync()
        sy.remove = [ts[1].id]
        XCTAssertThrowsError(try s.sync(subscription: sub!.id, sy) { _ in })
        XCTAssertEqual(try s.tunnels().count, 2, "a refused sync changes nothing")
        var up = ts[0]
        up.sha = String(repeating: "c", count: 64)
        sy = Store.Sync(add: [tunnel("C")], update: [up], remove: [])
        let added = try s.sync(subscription: sub!.id, sy) { added in XCTAssertEqual(added.count, 1) }
        XCTAssertEqual(added[0].name, "C")
        XCTAssertEqual(try s.tunnels().first { $0.id == ts[0].id }?.sha, up.sha)
        // A files error rolls the whole sync back.
        struct Boom: Error {}
        XCTAssertThrowsError(try s.sync(subscription: sub!.id, Store.Sync(add: [tunnel("D")])) { _ in throw Boom() })
        XCTAssertEqual(try s.tunnels().count, 3)
    }

    @MainActor
    func testUpdatesMatchRenamedAndSuffixedTunnels() {
        let existing = [tunnel("Alpha"), tunnel("Beta 2", sha: String(repeating: "b", count: 64)), tunnel("Renamed", sha: String(repeating: "c", count: 64))]
        let rows = [tunnel("alpha"), tunnel("Beta", sha: String(repeating: "x", count: 64)), tunnel("Gamma", sha: String(repeating: "c", count: 64)), tunnel("New", sha: String(repeating: "n", count: 64))]
        let (match, used) = AppModel.match(rows, to: existing)
        XCTAssertEqual(match, [0, 1, 2, nil], "by name, by the suffix an import adds, by identical options")
        XCTAssertEqual(used, [true, true, true])
    }

    // MARK: Files and secrets

    func testATunnelFileThatChangedOnDiskIsRefused() throws {
        let files = AppFiles(root: dir)
        let data = Data(#"{"type":"vless"}"#.utf8)
        var t = tunnel("A")
        t.id = 7
        t.sha = AppFiles.sha256(data)
        try files.writeTunnelSource(t, data)
        XCTAssertEqual(try files.tunnelSource(t), data)
        let attrs = try FileManager.default.attributesOfItem(atPath: files.tunnelFile(t).path)
        XCTAssertEqual((attrs[.posixPermissions] as? Int) ?? 0, 0o600)
        try Data("{}".utf8).write(to: files.tunnelFile(t))
        XCTAssertThrowsError(try files.tunnelSource(t))
        files.removeTunnelFiles(7)
        XCTAssertThrowsError(try files.tunnelSource(t))
    }

    func testSubscriptionHeadersAndChecksums() {
        let u = Fetch.parseUserinfo("upload=1; download=2; total=-5; expire=9")
        XCTAssertEqual(u, SubscriptionUsage(upload: 1, download: 2, total: nil, expire: 9), "a negative number is ignored")
        XCTAssertNil(Fetch.parseUserinfo("garbage"))
        XCTAssertEqual(Fetch.parseSums("abc  ir-cidr.list\ndef *ads.list\nbad line here\n"), ["ir-cidr.list": "abc", "ads.list": "def"])
        XCTAssertThrowsError(try Fetch.checkSubscriptionURL("http://example.com/sub?token=x"))
        XCTAssertThrowsError(try Fetch.checkSubscriptionURL("https://u:p@example.com/sub"))
        XCTAssertNoThrow(try Fetch.checkSubscriptionURL("https://example.com/sub?token=x"))
    }

    /// Errors name the host and never the address: it carries the user's token.
    func testErrorsDoNotLeakTheSubscriptionAddress() async {
        do {
            _ = try await Fetch.subscription(URL(string: "https://127.0.0.1:1/secret/path?token=SECRETTOKEN")!)
            XCTFail("expected a failure")
        } catch {
            XCTAssertFalse(error.localizedDescription.contains("SECRETTOKEN"), error.localizedDescription)
            XCTAssertFalse(error.localizedDescription.contains("/secret"), error.localizedDescription)
        }
    }

    // MARK: The move from the service

    func testACopyThatCannotBeReadIsNotReplacedByADefaultDatabase() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let newer = dir.appendingPathComponent("newer.db").path
        try DatabaseQueue(path: newer).write { try $0.execute(sql: "CREATE TABLE settings (id); PRAGMA user_version = \(Schema.migrations.count + 1)") }
        let files = AppFiles(root: dir.appendingPathComponent("app"))
        XCTAssertThrowsError(try LegacyMigration.copyDatabase(to: files, from: newer, lists: ""))
        XCTAssertFalse(FileManager.default.fileExists(atPath: files.databasePath), "the copy is retried at the next launch")
        let junk = dir.appendingPathComponent("junk.db").path
        try Data(repeating: 7, count: 4096).write(to: URL(fileURLWithPath: junk))
        XCTAssertNoThrow(try LegacyMigration.copyDatabase(to: files, from: junk, lists: ""), "not a database: start fresh")
    }

    func testTheServicesDatabaseIsCopiedOnceAndItsFilesImportedWithTheirHash() async throws {
        // A database the service wrote.
        let old = dir.appendingPathComponent("old.db").path
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let seed = try Store(path: old)
        let (sub, ts) = try seed.addTunnels([tunnel("Proxy", sha: AppFiles.sha256(Data(#"{"type":"vless"}"#.utf8))),
                                             tunnel("Work", kind: "openvpn", sha: AppFiles.sha256(Data("client\n".utf8)))], subscription: "P")
        try seed.setSelected(ts[0].id)
        try seed.setVPN(on: true)
        try seed.queue.close()

        let files = AppFiles(root: dir.appendingPathComponent("app"))
        try LegacyMigration.copyDatabase(to: files, from: old, lists: dir.appendingPathComponent("nolists").path)
        let s = try Store(path: files.databasePath)
        XCTAssertEqual(try s.migratedFrom(), LegacyMigration.pending)
        XCTAssertEqual(try s.vpn(), Store.VPN(on: true, selected: ts[0].id), "the VPN stays on across the move")
        // A second copy never overwrites.
        try s.setMigratedFrom("kept")
        try LegacyMigration.copyDatabase(to: files, from: old, lists: "")
        XCTAssertEqual(try Store(path: files.databasePath).migratedFrom(), "kept")
        try s.setMigratedFrom(LegacyMigration.pending)

        let legacy = WireLegacy(tunnels: [String(ts[0].id): .init(profile: nil, options: #"{"type":"vless"}"#),
                                          String(ts[1].id): .init(profile: "client\nTAMPERED\n", options: nil)],
                                subscriptions: [String(sub!.id): .init(url: "https://example.com/sub?token=t", usage: nil)])
        try LegacyMigration.importSecrets(legacy, store: s, files: files)
        XCTAssertEqual(try s.migratedFrom(), LegacyMigration.done)
        XCTAssertNoThrow(try files.tunnelSource(try s.tunnels()[0]))
        XCTAssertThrowsError(try files.tunnelSource(try s.tunnels()[1]), "a file that doesn't match its hash is not used")
        XCTAssertEqual(files.subscriptionURL(sub!.id), "https://example.com/sub?token=t")
    }
}

final class ImportDueTests: XCTestCase {
    func testDueRules() {
        let now = Date()
        func state(checked: Date?, error: String = "", force: Bool = false, hours: Int = 24) -> ImportState {
            var s = ImportState(name: "x", url: "https://example.com", refreshHours: hours)
            s.checkedAt = checked.map(Store.stamp) ?? ""
            s.lastError = error
            s.force = force
            return s
        }
        XCTAssertTrue(state(checked: nil).isDue(now), "never tried")
        XCTAssertFalse(state(checked: now.addingTimeInterval(-3600)).isDue(now))
        XCTAssertTrue(state(checked: now.addingTimeInterval(-25 * 3600)).isDue(now))
        XCTAssertTrue(state(checked: now.addingTimeInterval(-3600), force: true).isDue(now), "asked for")
        XCTAssertFalse(state(checked: now.addingTimeInterval(-60), error: "boom").isDue(now))
        XCTAssertTrue(state(checked: now.addingTimeInterval(-16 * 60), error: "boom").isDue(now), "a failure is retried after 15 minutes")
    }
}
