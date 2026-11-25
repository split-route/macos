import XCTest
@testable import Splitroute

@MainActor
final class FailoverTests: XCTestCase {
    private func t(_ id: Int64, _ name: String, kind: String = "vless", sub: Int64? = nil) -> StoreTunnel {
        var s = StoreTunnel(id: id, name: name, kind: kind, sha: String(repeating: "a", count: 64))
        s.subscriptionID = sub
        return s
    }

    func testCandidatesAreProxyServersOnlyNotTheCurrentOneNorARecentlyLeftOne() {
        let me = t(1, "me", sub: 7)
        let all = [me, t(2, "same-a", sub: 7), t(3, "ovpn", kind: "openvpn", sub: 7), t(4, "other", sub: 8), t(5, "same-b", sub: 7), t(6, "left", sub: 7), t(7, "lone")]
        let now = Date()
        let pool = AppModel.failoverPool(all, leaving: me, failedAt: ["left": now.addingTimeInterval(-60)], now: now)
        XCTAssertEqual(pool.map(\.name), ["same-a", "same-b", "other", "lone"], "the same subscription first, OpenVPN and the one just left never")
        // After ten minutes a left server may be tried again.
        let later = AppModel.failoverPool(all, leaving: me, failedAt: ["left": now.addingTimeInterval(-601)], now: now)
        XCTAssertTrue(later.map(\.name).contains("left"))
    }

    func testThePoolIsCapped() {
        let me = t(1, "me", sub: 1)
        let many = (2...100).map { t(Int64($0), "s\($0)", sub: 1) }
        XCTAssertEqual(AppModel.failoverPool([me] + many, leaving: me, failedAt: [:], now: Date()).count, AppModel.candidatePool)
    }
}
