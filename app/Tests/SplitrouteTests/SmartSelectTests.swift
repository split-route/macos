import XCTest
@testable import Splitroute

@MainActor
final class SmartSelectTests: XCTestCase {
    private func t(_ id: Int64, _ name: String, kind: String = "vless", sub: Int64? = nil) -> StoreTunnel {
        var s = StoreTunnel(id: id, name: name, kind: kind, sha: String(repeating: "a", count: 64))
        s.subscriptionID = sub
        return s
    }

    func testThePoolIsTheActiveServerThenProxyServersOfItsGroup() {
        let me = t(1, "me", sub: 7)
        let all = [me, t(2, "same-a", sub: 7), t(3, "ovpn", kind: "openvpn", sub: 7), t(4, "other", sub: 8), t(5, "same-b", sub: 7), t(6, "left", sub: 7), t(7, "lone")]
        let now = Date()
        let left = ["left": now.addingTimeInterval(-60)]
        XCTAssertEqual(AppModel.smartPool(all, active: me, scope: .group, failedAt: left, now: now).map(\.name),
                       ["me", "same-a", "same-b"], "its group only; OpenVPN and the one just left never")
        let later = AppModel.smartPool(all, active: me, scope: .group, failedAt: ["left": now.addingTimeInterval(-601)], now: now)
        XCTAssertTrue(later.map(\.name).contains("left"), "after ten minutes a left server may be tried again")
    }

    func testThereIsNoLimitAndTheActiveServerAndItsOwnGroupComeFirst() {
        let me = t(1, "me", sub: 7)
        let all = [me, t(2, "other-a", sub: 8), t(3, "same", sub: 7), t(4, "ovpn", kind: "openvpn", sub: 7)] + (5...300).map { t(Int64($0), "s\($0)", sub: 8) }
        let pool = AppModel.smartPool(all, active: me, scope: .all, failedAt: [:], now: Date())
        XCTAssertEqual(pool.count, 299, "every proxy server (300 minus the one OpenVPN), no cap")
        XCTAssertEqual(pool.prefix(2).map(\.name), ["me", "same"], "the active server, then its own group")
    }

    func testACustomListReplacesTheGroupAndNeverAddsOpenVPN() {
        let me = t(1, "me", sub: 7)
        let all = [me, t(2, "same", sub: 7), t(3, "ovpn", kind: "openvpn", sub: 8), t(4, "other", sub: 8), t(5, "lone")]
        let pool = AppModel.smartPool(all, active: me, scope: .custom([3, 4, 5]), failedAt: [:], now: Date())
        XCTAssertEqual(pool.map(\.name), ["me", "other", "lone"], "the active server is always measured; the list's proxy servers only")
    }

    func testPickMovesOnlyWhenAnotherIsFasterByMoreThanTheTolerance() {
        let r = ["a": 200, "b": 120, "c": 190]
        XCTAssertEqual(AppModel.smartPick(active: "a", results: r, tolerance: 50), "b", "80 ms faster")
        XCTAssertNil(AppModel.smartPick(active: "a", results: r, tolerance: 80), "exactly the tolerance is not more than it")
        XCTAssertNil(AppModel.smartPick(active: "b", results: r, tolerance: 0), "already the best")
        XCTAssertEqual(AppModel.smartPick(active: "a", results: ["a": 100, "b": 99], tolerance: 0), "b")
        XCTAssertNil(AppModel.smartPick(active: "a", results: ["a": 100, "b": 100], tolerance: 0), "a tie stays")
    }

    func testPickLeavesAServerThatDidNotAnswerWhateverTheTolerance() {
        XCTAssertEqual(AppModel.smartPick(active: "a", results: ["b": 900, "c": 400], tolerance: 200), "c")
        XCTAssertNil(AppModel.smartPick(active: "a", results: [:], tolerance: 0), "nothing answered: stay")
        XCTAssertEqual(AppModel.smartPick(active: nil, results: ["x": 5], tolerance: 100), "x")
    }
}
