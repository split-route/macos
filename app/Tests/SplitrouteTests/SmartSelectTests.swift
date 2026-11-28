import XCTest
@testable import Splitroute

@MainActor
final class SmartSelectTests: XCTestCase {
    private func t(_ id: Int64, _ name: String, kind: String = "vless", sub: Int64? = nil) -> StoreTunnel {
        var s = StoreTunnel(id: id, name: name, kind: kind, sha: String(repeating: "a", count: 64))
        s.subscriptionID = sub
        return s
    }

    func testThePoolStartsWithTheActiveServerThenProxyServersOfItsGroupFirst() {
        let me = t(1, "me", sub: 7)
        let all = [me, t(2, "same-a", sub: 7), t(3, "ovpn", kind: "openvpn", sub: 7), t(4, "other", sub: 8), t(5, "same-b", sub: 7), t(6, "left", sub: 7), t(7, "lone")]
        let now = Date()
        let left = ["left": now.addingTimeInterval(-60)]
        XCTAssertEqual(AppModel.smartPool(all, active: me, groupOnly: false, failedAt: left, now: now, limit: 99).map(\.name),
                       ["me", "same-a", "same-b", "other", "lone"], "its group first; OpenVPN and the one just left never")
        XCTAssertEqual(AppModel.smartPool(all, active: me, groupOnly: true, failedAt: left, now: now, limit: 99).map(\.name),
                       ["me", "same-a", "same-b"], "only its group when asked")
        let later = AppModel.smartPool(all, active: me, groupOnly: true, failedAt: ["left": now.addingTimeInterval(-601)], now: now, limit: 99)
        XCTAssertTrue(later.map(\.name).contains("left"), "after ten minutes a left server may be tried again")
    }

    func testThePoolIsCappedAndKeepsTheActiveServer() {
        let me = t(1, "me", sub: 1)
        let many = (2...100).map { t(Int64($0), "s\($0)", sub: 1) }
        let pool = AppModel.smartPool(many + [me], active: me, groupOnly: true, failedAt: [:], now: Date(), limit: 24)
        XCTAssertEqual(pool.count, 24)
        XCTAssertEqual(pool.first?.name, "me")
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
