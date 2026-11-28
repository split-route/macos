import XCTest
@testable import Splitroute

final class FlagsTests: XCTestCase {
    /// The flag is the stored country's; the name is never read for a place.
    func testFlagComesFromTheCountryNotTheName() {
        XCTAssertEqual(Flags.prefix(name: "irov", country: "DE"), "🇩🇪")
        XCTAssertNil(Flags.prefix(name: "Farhad Germany", country: ""), "a name that says Germany is not a country")
        XCTAssertNil(Flags.prefix(name: "DE-1 fast", country: ""))
        XCTAssertNil(Flags.prefix(name: "x", country: "D"), "not a two-letter code")
    }

    func testAServerBehindCloudflareGetsACloudNotAFlag() {
        XCTAssertEqual(Flags.prefix(name: "CDN vless", country: Flags.cdn), "☁️")
        XCTAssertNotEqual(Flags.prefix(name: "x", country: "CF"), "☁️", "CF is the Central African Republic's code")
    }

    func testAFlagAlreadyInTheNameIsNotRepeated() {
        XCTAssertEqual(Flags.existing(in: "🇩🇪 Berlin"), "🇩🇪")
        XCTAssertNil(Flags.prefix(name: "🇩🇪 Berlin", country: "DE"))
        XCTAssertNil(Flags.prefix(name: "🇩🇪 Berlin", country: "NL"), "the person's own flag is left as it is")
        XCTAssertNil(Flags.prefix(name: "Berlin 🇩🇪 fast", country: "DE"), "a flag anywhere in the name counts")
    }

    func testEmojiFromCode() {
        XCTAssertEqual(Flags.emoji(code: "de"), "🇩🇪")
        XCTAssertEqual(Flags.code(ofEmoji: "🇺🇸"), "US")
        XCTAssertNil(Flags.code(ofEmoji: "x"))
    }
}
