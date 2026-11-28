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
        XCTAssertEqual(try s.queue.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM entries") }, 1, "the import's entry stays; the custom list's moved into its rule")
        XCTAssertEqual(try s.config().lists.first?.rules.domainSuffix, ["example.com"], "an entry of a custom list becomes a field of its rule")
        XCTAssertEqual(try s.importLines("feed"), ["ads.example.net"])
        XCTAssertEqual(try s.queue.read { try Int.fetchOne($0, sql: "PRAGMA foreign_keys") }, 1, "turned back on afterwards")
        XCTAssertEqual(try s.queue.read { try Int.fetchOne($0, sql: "SELECT seq FROM sqlite_sequence WHERE name = 'tunnels'") }, 1, "ids are never reused")
        let backup = try DatabaseQueue(path: path + ".v3")
        XCTAssertEqual(try backup.read { try Int.fetchOne($0, sql: "PRAGMA user_version") }, 3, "the copy is the database as it was")
        XCTAssertEqual(try backup.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM entries") }, 2)
        XCTAssertEqual(try s.queue.read { try Int.fetchOne($0, sql: "PRAGMA user_version") }, Schema.migrations.count)
    }

    /// Migration 23: the lists and the default route of a database from before profiles become the profile "Default" (with
    /// their entries and import state), and settings no longer holds a server that could block its deletion.
    func testProfilesMigrationKeepsListsAndTheDefaultRoute() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("db.sqlite").path
        let q = try DatabaseQueue(path: path)
        let before = try XCTUnwrap(Schema.migrations.firstIndex { $0.contains("CREATE TABLE profiles") }) // the schema before profiles
        try q.write { db in
            for m in Schema.migrations.prefix(before) { try db.execute(sql: m) }
            try db.execute(sql: "PRAGMA user_version = \(before)")
            try db.execute(sql: "INSERT INTO settings (id, created_at) VALUES (1, 'x')")
            try db.execute(sql: "INSERT INTO tunnels (name, profile_sha256, position, created_at, updated_at) VALUES ('Work', '\(String(repeating: "b", count: 64))', 0, 'x', 'x')")
            try db.execute(sql: "UPDATE settings SET final_action = 'tunnel', final_tunnel_id = 1")
            try db.execute(sql: "INSERT INTO lists (name, source, action, position, created_at, updated_at) VALUES ('feed', 'import', 'block', 0, 'x', 'x')")
            try db.execute(sql: "INSERT INTO import_sources (list_id, url) VALUES (1, 'https://example.com/x')")
            try db.execute(sql: "INSERT INTO entries (list_id, position, kind, value) VALUES (1, 0, 'domain_suffix', 'ads.example.net')")
        }
        try q.close()
        let s = try Store(path: path)
        let cfg = try s.config()
        XCTAssertEqual(cfg.profiles, ["Default"])
        XCTAssertEqual(cfg.activeProfile, "Default")
        XCTAssertEqual(cfg.lists.map(\.name), ["feed"])
        XCTAssertEqual(cfg.finalTunnel, "Work", "the default route moved to the profile")
        XCTAssertEqual(try s.importLines("feed"), ["ads.example.net"])
        // Migration 25 made the route global again: it is in settings, and the profiles hold none.
        XCTAssertEqual(try s.queue.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM profiles WHERE final_tunnel_id IS NOT NULL") }, 0)
        XCTAssertEqual(try s.queue.read { try Int.fetchOne($0, sql: "PRAGMA foreign_keys") }, 1)
        XCTAssertEqual(try DatabaseQueue(path: path + ".v\(before)").read { try Int.fetchOne($0, sql: "PRAGMA user_version") }, before)
    }

    // MARK: Profiles

    /// A profile has its own lists; the same list name can be in two profiles; switching shows each its own. The default route is
    /// global: it is the same whichever profile is active.
    func testProfilesKeepTheirOwnListsAndShareTheDefaultRoute() throws {
        let s = try newStore()
        _ = try s.addTunnels([tunnel("A")])
        try s.update { try $0.removing("ir-cidr") } // the list a new database starts with
        try s.update { var c = try $0.creating("Office", .direct); c.finalAction = .block; return c }
        XCTAssertEqual(try s.config().lists.map(\.name), ["Office"])

        XCTAssertEqual(try s.createProfile("  Travel "), "Travel", "the name is tidied")
        var c = try s.config()
        XCTAssertEqual(c.activeProfile, "Travel", "a new profile becomes the active one")
        XCTAssertEqual(c.profiles, ["Default", "Travel"])
        XCTAssertEqual(c.lists, [], "and starts empty")
        XCTAssertEqual(c.finalAction, .block, "the default route is the global one")
        try s.update { try $0.creating("Streaming", .tunnel) }
        try s.update { var c = $0; c.finalAction = .direct; return c }

        try s.setActiveProfile("Default")
        c = try s.config()
        XCTAssertEqual(c.lists.map(\.name), ["Office"], "Default is untouched by what Travel did")
        XCTAssertEqual(c.finalAction, .direct, "a change of the default route in one profile is a change in every profile")
        try s.update { try $0.creating("Streaming", .block) } // the same name as in Travel: fine in another profile
        XCTAssertEqual(try s.config().lists.map(\.name), ["Office", "Streaming"])
        try s.setActiveProfile("Travel")
        XCTAssertEqual(try s.config().lists.map(\.name), ["Streaming"])
        XCTAssertEqual(try s.config().lists.first?.action, .tunnel, "each profile's Streaming is its own")
    }

    func testProfileNamesAreUniqueAndTheLastProfileStays() throws {
        let s = try newStore()
        XCTAssertThrowsError(try s.createProfile("default"), "ignoring case")
        XCTAssertThrowsError(try s.createProfile("   "))
        try s.createProfile("Work")
        XCTAssertThrowsError(try s.renameProfile("Work", to: "DEFAULT"))
        try s.renameProfile("Work", to: "Work")  // its own name is fine
        try s.renameProfile("Work", to: "Office")
        XCTAssertEqual(try s.config().profiles, ["Default", "Office"])
        XCTAssertEqual(try s.deleteProfile("Office"), "Default", "the active one was deleted: the first other takes over")
        XCTAssertThrowsError(try s.deleteProfile("Default"), "the only profile")
        XCTAssertThrowsError(try s.setActiveProfile("Nope"))
    }

    /// Deleting a profile deletes its lists, their entries and import state, and no other profile's.
    func testDeletingAProfileDeletesItsListsOnly() throws {
        let s = try newStore()
        func addFeed() throws {
            try s.update { var c = $0; var l = RouteList(name: "feed", action: .block); l.importSource = ImportSource(url: "https://example.com/x", refreshHours: nil); c.lists.append(l); return c }
            try s.saveDownload(name: "feed", url: "https://example.com/x", lines: ["ads.example.net"], etag: "", lastModified: "", sha256: String(repeating: "c", count: 64), skipped: 0)
        }
        try addFeed()
        try s.createProfile("Other")
        try addFeed() // the same list in the new profile, with its own entries
        XCTAssertEqual(try s.queue.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM entries") }, 2)
        try s.deleteProfile("Other")
        XCTAssertEqual(try s.config().activeProfile, "Default")
        XCTAssertEqual(try s.importLines("feed"), ["ads.example.net"], "the original keeps its entries")
        XCTAssertEqual(try s.queue.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM entries") }, 1)
        XCTAssertEqual(try s.queue.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM import_sources") }, 1)
    }

    /// A server another profile's rule uses can't be deleted either, and the message names the profile.
    func testAServerUsedByAnotherProfileIsProtected() throws {
        let s = try newStore()
        let t = try s.addTunnels([tunnel("A")]).tunnels[0]
        try s.createProfile("Work")
        try s.update { var c = try $0.creating("Streaming", .tunnel); c.lists[c.lists.count - 1].tunnel = "A"; return c }
        try s.setActiveProfile("Default")
        XCTAssertEqual(try s.listsUsing(tunnel: t.id), ["Work › Streaming"])
        XCTAssertThrowsError(try s.removeTunnel(t.id))
        // The default route is global and protects the server too, by that name.
        try s.update { var c = $0; c.finalAction = .tunnel; c.finalTunnel = "A"; return c }
        XCTAssertEqual(try s.listsUsing(tunnel: t.id), ["Work › Streaming", "Default Route"])
    }

    /// Migration 25: the default route is global again. The active profile's becomes the global one, and the profiles' own are cleared so
    /// they can't block deleting a server.
    func testTheDefaultRouteMovesBackToSettingsFromTheActiveProfile() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("db.sqlite").path
        let q = try DatabaseQueue(path: path)
        let before = try XCTUnwrap(Schema.migrations.firstIndex { $0.contains("The default route is global again") })
        try q.write { db in
            for m in Schema.migrations.prefix(before) { try db.execute(sql: m) }
            try db.execute(sql: "PRAGMA user_version = \(before)")
            try db.execute(sql: "INSERT INTO settings (id, created_at) VALUES (1, 'x')")
            try db.execute(sql: "INSERT INTO tunnels (name, profile_sha256, position, created_at, updated_at) VALUES ('Work', '\(String(repeating: "b", count: 64))', 0, 'x', 'x')")
            try db.execute(sql: "INSERT INTO profiles (id, name, position, final_action, final_tunnel_id, created_at) VALUES (2, 'Other', 1, 'block', NULL, 'x')")
            try db.execute(sql: "UPDATE profiles SET final_action = 'tunnel', final_tunnel_id = 1 WHERE id = 1")
            try db.execute(sql: "UPDATE settings SET active_profile_id = 1")
        }
        try q.close()
        let s = try Store(path: path)
        let c = try s.config()
        XCTAssertEqual(c.finalAction, .tunnel)
        XCTAssertEqual(c.finalTunnel, "Work", "the active profile's route is the global one")
        XCTAssertEqual(try s.queue.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM profiles WHERE final_tunnel_id IS NOT NULL OR final_action <> 'tunnel'") }, 0)
        XCTAssertThrowsError(try s.removeTunnel(1), "the global default route holds the server")
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

    /// The typed forms a plain list uses (v2fly's keyword:, regexp:, full:) become fields of a rule, and the stored kinds
    /// of the text imports still read back.
    func testPlainListLinesBecomeTheFieldsOfARule() {
        let r = RuleSpec(canonicalLines: ["# why", "keyword:tracker", #"regexp:^ads[0-9]+\.net$"#, "port:443", "port:8000-9000", "app:/Applications/Safari.app",
                                          "process:curl", "full:www.example.com", "example.com", "203.0.113.0/24", "2400:cb00::/32", "AS13335"])
        XCTAssertEqual(r.domainKeyword, ["tracker"])
        XCTAssertEqual(r.domainRegex, [#"^ads[0-9]+\.net$"#])
        XCTAssertEqual(r.port, [443])
        XCTAssertEqual(r.portRange, ["8000:9000"], "sing-box writes a range with a colon")
        XCTAssertEqual(r.applications, ["/Applications/Safari.app"])
        XCTAssertEqual(r.processName, ["curl"])
        XCTAssertEqual(r.domain, ["www.example.com"])
        XCTAssertEqual(r.domainSuffix, ["example.com"])
        XCTAssertEqual(r.ipCIDR, ["203.0.113.0/24", "2400:cb00::/32"])
        XCTAssertEqual(Entries.kind("keyword:x"), "keyword")
        XCTAssertEqual(Entries.kind("2400:cb00::/32"), "cidr", "an IPv6 address is not a typed entry")
        XCTAssertEqual(Entries.value("regexp:^a"), "^a")
    }

    /// The rule's JSON is the core's: the names are sing-box's, and only what is set is written.
    func testRuleSpecJSONIsTheCoresAndOmitsWhatIsEmpty() throws {
        var r = RuleSpec()
        r.domainSuffix = ["example.com"]; r.port = [443]; r.processPathRegex = ["^/opt/"]
        let json = String(decoding: try { let e = JSONEncoder(); e.outputFormatting = .sortedKeys; return try e.encode(r) }(), as: UTF8.self)
        XCTAssertEqual(json, #"{"domain_suffix":["example.com"],"port":[443],"process_path_regex":["^\/opt\/"]}"#)
        r.mode = "and"; r.invert = true
        XCTAssertTrue(String(decoding: try JSONEncoder().encode(r), as: UTF8.self).contains(#""mode":"and""#))
        XCTAssertEqual(try JSONDecoder().decode(RuleSpec.self, from: Data(#"{"domain":["a.com"]}"#.utf8)).mode, "or", "no mode is or")
    }

    /// A rule-set kept as it was imported lives in the database untouched, and a changed address drops it.
    func testARuleSetIsKeptAsItIsAndDroppedWithItsAddress() throws {
        let s = try newStore()
        try s.update { try $0.importing("Feed", .block, url: "https://example.com/a.srs") }
        let bytes = Data("SRS\u{05}whatever the service checked".utf8)
        XCTAssertTrue(try s.saveRuleSetDownload(name: "Feed", url: "https://example.com/a.srs", data: bytes, etag: "e", lastModified: "", sha256: "h"))
        XCTAssertEqual(try s.ruleSetData("Feed"), bytes)
        XCTAssertTrue(try s.config().lists.first { $0.name == "Feed" }!.ruleSet)
        XCTAssertTrue(try s.imports()[0].hasRuleSet)
        try s.update { try $0.settingDescription("Feed", "mine") }
        XCTAssertEqual(try s.ruleSetData("Feed"), bytes, "an unrelated edit keeps the download")
        try s.update { try $0.settingImportURL("Feed", to: "https://example.com/b.srs") }
        XCTAssertNil(try s.ruleSetData("Feed"), "a rule-set from another address would mislead")
        try s.update { try $0.creating("Mine", .block) }
        try s.setRuleSet(name: "Mine", data: bytes)
        XCTAssertTrue(try s.config().lists.first { $0.name == "Mine" }!.ruleSet)
    }

    /// Renaming a list with `renameList` keeps a rule-set that lives only in the database.
    func testRenamingARuleSetListKeepsItsBytes() throws {
        let s = try newStore()
        try s.update { try $0.creating("Shared", .block) }
        let bytes = Data("SRS\u{05}x".utf8)
        try s.setRuleSet(name: "Shared", data: bytes)
        try s.renameList("Shared", to: "Renamed")
        XCTAssertEqual(try s.ruleSetData("Renamed"), bytes)
        XCTAssertTrue(try s.config().lists.first { $0.name == "Renamed" }!.ruleSet)
    }

    func testListRulesRefuseWhatTheyMust() throws {
        let c = Config.initial
        XCTAssertThrowsError(try c.enablingRelease("ir-cidr", .direct)) // twice
        XCTAssertThrowsError(try c.enablingRelease("Bad Name", .direct))
        XCTAssertThrowsError(try c.importing("feed", .block, url: "http://example.com/x")) // not https
        XCTAssertThrowsError(try c.importing("feed", .block, url: "https://user:pw@example.com/x"))
        XCTAssertThrowsError(try c.renaming("ir-cidr", to: "other")) // a release list
        XCTAssertThrowsError(try c.settingAction("ir-cidr", .block, tunnel: "Work")) // only a tunnel list names a tunnel
        XCTAssertThrowsError(try c.creating("x", .direct).settingRules("ir-cidr", RuleSpec())) // not custom
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
