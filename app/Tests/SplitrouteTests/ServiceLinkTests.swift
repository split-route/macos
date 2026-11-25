import XCTest
@testable import Splitroute

/// The snapshot is the contract with the service (daemon/internal/api). `goldenSnapshot` is the same JSON the Go test
/// `TestSnapshotFromTheApp` decodes and validates: change both together.
@MainActor
final class ServiceLinkTests: XCTestCase {
    var dir: URL!

    override func setUp() { dir = FileManager.default.temporaryDirectory.appendingPathComponent("sr-\(UUID().uuidString)") }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    static let goldenSnapshot = ##"{"block_quic":true,"lists":[{"action":"direct","format":"rules","name":"Office","rules":{"domain_suffix":["example.com"],"ip_cidr":["8.8.8.0\/24"]}},{"action":"block","name":"malware"},{"action":"tunnel","format":"rules","name":"Work list","rules":{"domain":["a.example.com"],"mode":"and","port":[443]},"tunnel":"Work"}],"lists_on":true,"retry":["*"],"selected":"t1","tunnels":[{"id":"t1","name":"Proxy","needs_auth":false,"options":{"server":"example.com","server_port":443,"type":"vless"},"protocol":"vless"},{"id":"t2","name":"Work","needs_auth":true,"password":"pw","profile":"client\n","protocol":"openvpn","username":"alice"}],"vpn":true}"##

    func make() throws -> (Store, AppFiles, ServiceLink) {
        let files = AppFiles(root: dir)
        let s = try Store(path: files.databasePath)
        return (s, files, ServiceLink(store: s, files: files))
    }

    func add(_ s: Store, _ files: AppFiles, _ name: String, kind: String, source: String, needsAuth: Bool = false) throws -> StoreTunnel {
        let data = Data(source.utf8)
        var t = StoreTunnel(id: 0, name: name, kind: kind, sha: AppFiles.sha256(data), remotes: [])
        t.needsAuth = needsAuth
        t = try s.addTunnels([t]).tunnels[0]
        try files.writeTunnelSource(t, data)
        return t
    }

    /// Disconnect on sleep: the snapshot says the VPN is off while the saved switch stays on.
    func testSuspendedSnapshotSaysVPNIsOffAndTheSavedSwitchStaysOn() throws {
        let (s, files, link) = try make()
        let proxy = try add(s, files, "Proxy", kind: "vless", source: #"{"type":"vless","server":"example.com","server_port":443}"#)
        try s.setSelected(proxy.id)
        try s.setVPN(on: true)
        XCTAssertTrue(try link.snapshot().vpn)
        link.suspended = true
        XCTAssertFalse(try link.snapshot().vpn)
        XCTAssertTrue(try s.vpn().on, "the saved switch is the user's: sleep never writes it")
        link.suspended = false
        XCTAssertTrue(try link.snapshot().vpn)
    }

    func testSnapshotMatchesTheServicesContract() throws {
        let (s, files, link) = try make()
        let proxy = try add(s, files, "Proxy", kind: "vless", source: #"{"type":"vless","server":"example.com","server_port":443}"#)
        _ = try add(s, files, "Work", kind: "openvpn", source: "client\n", needsAuth: true)
        try s.setSelected(proxy.id)
        try s.setVPN(on: true)
        try s.update { c in
            var c = try c.creating("Office", .direct)
            var office = RuleSpec(); office.domainSuffix = ["example.com"]; office.ipCIDR = ["8.8.8.0/24"]
            c = try c.settingRules("Office", office)
            c = try c.enablingRelease("malware", .block)
            c = try c.creating("Work list", .tunnel)
            c.lists[c.lists.count - 1].tunnel = "Work"
            var work = RuleSpec(); work.mode = "and"; work.domain = ["a.example.com"]; work.port = [443]
            return try c.settingRules("Work list", work)
        }
        try s.update { try $0.removing("ir-cidr") }
        link.credentials = { $0 == "Work" ? TunnelSecrets(username: "alice", password: "pw", keyPassword: "") : nil }
        link.retry("*")
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let json = String(decoding: try enc.encode(try link.snapshot()), as: UTF8.self)
        XCTAssertEqual(json, Self.goldenSnapshot)
        XCTAssertEqual(link.sentCredentials, ["Work"])
    }

    func testKillSwitchIsSentOnlyWhenOnAndTheLANFlagOnlyWithIt() throws {
        let (s, _, link) = try make()
        XCTAssertEqual(try s.killSwitch(), Store.KillSwitch(on: false, lan: true), "off by default, LAN allowed")
        var snap = try link.snapshot()
        XCTAssertNil(snap.killSwitch)
        XCTAssertNil(snap.killSwitchLAN)
        try s.setKillSwitch(on: true)
        snap = try link.snapshot()
        XCTAssertEqual(snap.killSwitch, true)
        XCTAssertEqual(snap.killSwitchLAN, true)
        try s.setKillSwitch(lan: false)
        snap = try link.snapshot()
        XCTAssertEqual(snap.killSwitch, true)
        XCTAssertNil(snap.killSwitchLAN)
        try s.setKillSwitch(on: false, lan: true)
        snap = try link.snapshot()
        XCTAssertNil(snap.killSwitch)
        XCTAssertNil(snap.killSwitchLAN, "a stale LAN flag is never sent while the kill switch is off")
    }

    func testBootstrapIsSentOnlyWhenChosen() throws {
        let (s, _, link) = try make()
        XCTAssertEqual(try s.bootstrap(), "")
        XCTAssertNil(try link.snapshot().bootstrap)
        try s.setBootstrap("8.8.8.8")
        XCTAssertEqual(try link.snapshot().bootstrap, "8.8.8.8")
        try s.setBootstrap("")
        XCTAssertNil(try link.snapshot().bootstrap)
    }

    func testATunnelWhoseFileIsGoneIsReportedNotSent() throws {
        let (s, files, link) = try make()
        let a = try add(s, files, "A", kind: "vless", source: #"{"type":"vless"}"#)
        let b = try add(s, files, "B", kind: "vless", source: #"{"type":"vless"}"#)
        try s.setSelected(a.id)
        try s.setVPN(on: true)
        files.removeTunnelFiles(a.id)
        try Data("{}".utf8).write(to: files.tunnelFile(b)) // changed after import
        let snap = try link.snapshot()
        XCTAssertEqual(snap.tunnels.count, 0)
        XCTAssertNil(snap.selected, "a selected tunnel that can't be sent is not named")
        XCTAssertEqual(Set(link.problems.keys), [a.coreID, b.coreID])
    }

    func testRefusedCredentialsAreNotResent() throws {
        let (s, files, link) = try make()
        _ = try add(s, files, "Work", kind: "openvpn", source: "client\n", needsAuth: true)
        link.credentials = { _ in nil } // the model returns nil for a tunnel whose saved credentials the server refused
        let snap = try link.snapshot()
        XCTAssertNil(snap.tunnels[0].username)
        XCTAssertTrue(link.sentCredentials.isEmpty)
    }

    func testPushesOnlyWhenSomethingChangedOrTheServiceRestarted() throws {
        let (_, _, link) = try make()
        XCTAssertTrue(link.dirty, "the first snapshot goes out")
        link.saw(bootID: "a")
        link.saw(bootID: "a")
        XCTAssertEqual(link.bootID, "a")
    }
}

final class StatusDecodeTests: XCTestCase {
    /// A fresh service has applied nothing: Go sends null for the unset slice and map. That must not read as "outdated".
    func testStatusWithNullListsAndTunnelsDecodes() throws {
        let json = #"{"version":"dev","api_rev":3,"boot_id":"x","running":false,"connected":0,"tunnels":null,"lists":null}"#
        let s = try JSONDecoder().decode(ServiceStatus.self, from: Data(json.utf8))
        XCTAssertEqual(s.lists, [])
        XCTAssertTrue(s.tunnels.isEmpty)
    }
}
