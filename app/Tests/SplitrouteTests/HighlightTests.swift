import Design
import XCTest

final class HighlightTests: XCTestCase {
    func testMatchesIgnoreCaseAndAccents() {
        XCTAssertTrue(Highlight.matches("Block QUIC (HTTP/3)", "quic"))
        XCTAssertTrue(Highlight.matches("Café", "cafe"))
        XCTAssertTrue(Highlight.matches("anything", "  "), "an empty query matches everything")
        XCTAssertFalse(Highlight.matches("Kill switch", "stun"))
    }

    func testEveryOccurrenceIsMarked() {
        let text = Highlight.attributed("Test the test", "TEST")
        let marked = text.runs.filter { $0.backgroundColor != nil }.map { String(text[$0.range].characters) }
        XCTAssertEqual(marked, ["Test", "test"])
        XCTAssertEqual(text.runs.filter { $0.backgroundColor != nil }.count, 2)
        XCTAssertNil(Highlight.attributed("none here", "zzz").runs.first { $0.backgroundColor != nil })
    }
}
