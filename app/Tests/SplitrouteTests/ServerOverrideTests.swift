import XCTest
@testable import Splitroute

final class ServerOverrideTests: XCTestCase {
    func testServersAsTyped() throws {
        XCTAssertNil(try OvpnProfile.parseServer("  "))
        XCTAssertEqual(try OvpnProfile.parseServer("vpn.example.com"), .init(host: "vpn.example.com", port: nil))
        XCTAssertEqual(try OvpnProfile.parseServer("vpn.example.com:443"), .init(host: "vpn.example.com", port: 443))
        XCTAssertEqual(try OvpnProfile.parseServer("203.0.113.7:1194"), .init(host: "203.0.113.7", port: 1194))
        XCTAssertEqual(try OvpnProfile.parseServer("[2001:db8::1]:443"), .init(host: "2001:db8::1", port: 443))
        XCTAssertEqual(try OvpnProfile.parseServer("2001:db8::1"), .init(host: "2001:db8::1", port: nil), "a bare IPv6 address has no port")
        for bad in ["bad host", "vpn.example.com:0", "vpn.example.com:70000", "vpn.example.com:abc", "[2001:db8::1", "-bad.example.com", "a_b.example.com"] {
            XCTAssertThrowsError(try OvpnProfile.parseServer(bad), bad)
        }
    }

    func testTheRemoteLinesAreReplacedByTheOneServer() throws {
        let profile = """
        client
        dev tun
        remote a.example.net 1194 udp
        remote b.example.net 443 tcp
        <ca>
        remote inside.a.block
        </ca>
        auth-user-pass
        """
        let host = try OvpnProfile.overridingServer(profile, with: "vpn.example.com")
        XCTAssertEqual(host.components(separatedBy: "\n").filter { $0.hasPrefix("remote vpn.example.com") }, ["remote vpn.example.com 1194 udp"],
                       "the first remote's port and protocol are kept when the override gives none")
        XCTAssertFalse(host.contains("a.example.net") || host.contains("b.example.net"), "every original remote is gone")
        XCTAssertTrue(host.contains("remote inside.a.block"), "text inside a block is not a directive")
        XCTAssertTrue(host.contains("auth-user-pass") && host.contains("dev tun"), "everything else is untouched")
        let withPort = try OvpnProfile.overridingServer(profile, with: "vpn.example.com:8443")
        XCTAssertTrue(withPort.contains("remote vpn.example.com 8443 udp"))
        XCTAssertEqual(try OvpnProfile.overridingServer(profile, with: ""), profile, "no override changes nothing")
        XCTAssertThrowsError(try OvpnProfile.overridingServer("client\ndev tun\n", with: "vpn.example.com"), "a profile with no remote")
    }

    func testTheOverrideIsStoredAndTheProfileIsNotChanged() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sr-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = try Store(path: dir.appendingPathComponent("db.sqlite").path)
        let t = try s.addTunnels([StoreTunnel(id: 0, name: "Work", kind: "openvpn", sha: String(repeating: "a", count: 64), remotes: ["a.example.net:1194"])]).tunnels[0]
        XCTAssertEqual(try s.tunnels()[0].serverOverride, "")
        try s.setServerOverride(t.id, "vpn.example.com:443")
        XCTAssertEqual(try s.tunnels()[0].serverOverride, "vpn.example.com:443")
        XCTAssertEqual(try s.tunnels()[0].sha, t.sha, "the profile's hash is the profile's: the override is separate")
        try s.setServerOverride(t.id, "")
        XCTAssertEqual(try s.tunnels()[0].serverOverride, "")
    }
}
