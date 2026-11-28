import Design
import XCTest
@testable import Splitroute

final class ServersTests: XCTestCase {
    func testLatencyFilter() {
        XCTAssertTrue(LatencyFilter.all.allows(nil))
        XCTAssertFalse(LatencyFilter.answered.allows(nil), "no result yet")
        XCTAssertFalse(LatencyFilter.answered.allows(.failed("Timeout", detail: nil)))
        XCTAssertTrue(LatencyFilter.answered.allows(.ms(900)))
        XCTAssertTrue(LatencyFilter.under300.allows(.ms(299)))
        XCTAssertFalse(LatencyFilter.under300.allows(.ms(300)))
        XCTAssertEqual(LatencyFilter.allCases.map(\.title), ["All servers", "Answered the test", "Under 100 ms", "Under 300 ms", "Under 500 ms"])
        XCTAssertFalse(LatencyFilter.under100.allows(.failed("Failed", detail: nil)))
    }

    func testQuotaColors() {
        let gb: Int64 = 1_000_000_000
        XCTAssertEqual(TunnelsPage.quota(used: 10 * gb, total: 100 * gb), .fine)
        XCTAssertEqual(TunnelsPage.quota(used: 85 * gb, total: 100 * gb), .fine, "exactly 15 percent left is still fine")
        XCTAssertEqual(TunnelsPage.quota(used: 90 * gb, total: 100 * gb), .low(10))
        XCTAssertEqual(TunnelsPage.quota(used: 97 * gb, total: 100 * gb), .low(3))
        XCTAssertEqual(TunnelsPage.quota(used: 100 * gb, total: 100 * gb), .out)
        XCTAssertEqual(TunnelsPage.quota(used: 120 * gb, total: 100 * gb), .out)
        XCTAssertEqual(TunnelsPage.quota(used: 5, total: 0), .fine, "no plan size, nothing to say")
    }
}

final class DestinationTests: XCTestCase {
    func testASavedPageWithAnOldNameMovesToTheNewOne() {
        let d = UserDefaults(suiteName: "destination-tests-\(UUID().uuidString)")!
        for (old, new) in [("Settings", "General"), ("Connection", "General"), ("Network", "General"), ("Updates", "General"), ("Lists", "Lists"), ("Home", "Home")] {
            d.set(old, forKey: "settingsPage")
            Destination.migrateStoredPage(d)
            XCTAssertEqual(d.string(forKey: "settingsPage"), new)
            XCTAssertNotNil(Destination(rawValue: d.string(forKey: "settingsPage")!), "\(new) is a page")
        }
        Destination.migrateStoredPage(d, key: "missing") // nothing saved: nothing to do
        XCTAssertNil(d.string(forKey: "missing"))
    }

    func testEveryPageHasItsOwnRawValueAndTitle() {
        XCTAssertEqual(Destination.allCases.map(\.rawValue).count, Set(Destination.allCases.map(\.rawValue)).count)
        XCTAssertEqual(Destination.general.rawValue, "General")
        XCTAssertEqual(Destination.application.rawValue, "Application")
        XCTAssertEqual(Destination.application.title, "Application")
        XCTAssertEqual(Destination.settingsPages.count, Destination.settingsPages.compactMap(\.subtitle).count, "each settings page has a subtitle")
    }
}
