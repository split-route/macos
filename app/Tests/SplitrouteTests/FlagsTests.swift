import XCTest
@testable import Splitroute

final class FlagsTests: XCTestCase {
    func testCountryNamesAndCodes() {
        let cases: [(String, String?)] = [
            ("Farhad Germany", "DE"), ("DE-1 fast", "DE"), ("Frankfurt DE", "DE"), ("US West", "US"), ("United States 2", "US"),
            ("UK London", "GB"), ("South Korea", "KR"), ("Netherlands", "NL"), ("holland 3", "NL"),
            // names that must not get a flag
            ("CDM tls WS CDN vless", nil), ("ws trojan CDM IP4", nil), ("irov", nil), ("Iranian CDN", nil), ("httpupgrade vless HC CDM IP4", nil),
        ]
        for (name, want) in cases { XCTAssertEqual(Flags.code(in: name), want, name) }
    }

    func testExistingEmojiWinsAndIsNotRepeated() {
        XCTAssertEqual(Flags.existing(in: "🇩🇪 Berlin"), "🇩🇪")
        XCTAssertNil(Flags.prefix(for: ["🇩🇪 Berlin"]), "the name already shows it")
        XCTAssertEqual(Flags.prefix(for: ["Berlin", "Farhad Germany"]), "🇩🇪", "the group's name counts when the server's has none")
        XCTAssertNil(Flags.prefix(for: ["irov", nil]))
    }

    func testEmojiFromCode() {
        XCTAssertEqual(Flags.emoji(code: "de"), "🇩🇪")
        XCTAssertEqual(Flags.code(ofEmoji: "🇺🇸"), "US")
        XCTAssertNil(Flags.code(ofEmoji: "x"))
    }
}
