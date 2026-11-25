import XCTest
@testable import Splitroute

final class PrefsTests: XCTestCase {
    func testTestURLMustBePlainHTTPS() {
        let cases: [(String, Bool)] = [
            ("https://www.gstatic.com/generate_204", true),
            ("  https://cp.cloudflare.com/generate_204  ", true),
            ("http://example.com/x", false),
            ("file:///etc/passwd", false),
            ("example.com", false),
            ("https://user:pw@example.com/", false),
            ("https:///x", false),
            ("", false),
            ("https://example.com/" + String(repeating: "a", count: 3000), false),
        ]
        for (raw, ok) in cases { XCTAssertEqual(Prefs.validTestURL(raw) != nil, ok, raw) }
    }

    func testPresetsAreValid() {
        for p in Prefs.testURLPresets { XCTAssertNotNil(Prefs.validTestURL(p.url), p.name) }
        XCTAssertNotNil(Prefs.validTestURL(Prefs.defaultTestURL))
    }
}
