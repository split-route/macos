import XCTest
@testable import Splitroute

final class SmartListsTests: XCTestCase {
    func testListsRoundTripThroughPreferences() throws {
        let d = UserDefaults(suiteName: "smart-lists-\(UUID().uuidString)")!
        XCTAssertEqual(SmartLists.load(d), [], "none to start with")
        let a = SmartList(name: "Fast", servers: [3, 1, 2])
        SmartLists.save([a, SmartList(name: "Work", servers: [])], d)
        XCTAssertEqual(SmartLists.load(d).map(\.name), ["Fast", "Work"])
        XCTAssertEqual(SmartLists.load(d).first, a, "the servers keep their order")
        d.set(Data("not json".utf8), forKey: Prefs.smartLists)
        XCTAssertEqual(SmartLists.load(d), [], "a damaged value reads as no lists")
    }

    func testARemovedServerLeavesEveryListAndTheRestStays() {
        let lists = [SmartList(name: "A", servers: [1, 2, 3]), SmartList(name: "B", servers: [2]), SmartList(name: "C", servers: [4])]
        let pruned = SmartLists.removing(missingFrom: [1, 3, 4], in: lists)
        XCTAssertEqual(pruned.map(\.servers), [[1, 3], [], [4]])
        XCTAssertEqual(pruned.map(\.name), ["A", "B", "C"], "an emptied list stays, empty")
    }

    func testNamesAreTidiedAndUniqueIgnoringCase() throws {
        let a = SmartList(name: "Fast")
        let lists = [a, SmartList(name: "Work")]
        XCTAssertEqual(try SmartLists.validName("  Night \n shift ", among: lists), "Night shift")
        XCTAssertThrowsError(try SmartLists.validName("   ", among: lists))
        XCTAssertThrowsError(try SmartLists.validName("work", among: lists))
        XCTAssertEqual(try SmartLists.validName("FAST", among: lists, excluding: a.id), "FAST", "its own name is fine")
    }

    func testTheScopeValueNamesTheList() {
        let id = UUID()
        XCTAssertEqual(SmartLists.listID(in: SmartLists.scopeValue(id)), id)
        XCTAssertNil(SmartLists.listID(in: "all"))
        XCTAssertNil(SmartLists.listID(in: "list:nonsense"))
    }
}
