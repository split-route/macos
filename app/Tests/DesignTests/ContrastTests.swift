import XCTest
@testable import Design

final class ContrastTests: XCTestCase {
    func testLinesReadAgainstBothGrounds() {
        for dark in [false, true] {
            for ground in [Palette.ground, Palette.surface] {
                for line in Line.allCases {
                    let r = Contrast.ratio(line.tone.hex(dark: dark), ground.hex(dark: dark))
                    XCTAssertGreaterThanOrEqual(r, 3, "\(line.name) \(dark ? "dark" : "light") on \(ground): \(r)")
                }
            }
        }
    }

    func testTextTones() {
        for dark in [false, true] {
            for ground in [Palette.ground, Palette.surface] {
                XCTAssertGreaterThanOrEqual(Contrast.ratio(Palette.ink.hex(dark: dark), ground.hex(dark: dark)), 7)
                XCTAssertGreaterThanOrEqual(Contrast.ratio(Palette.inkSecondary.hex(dark: dark), ground.hex(dark: dark)), 4.5)
                XCTAssertGreaterThanOrEqual(Contrast.ratio(Palette.danger.hex(dark: dark), ground.hex(dark: dark)), 4.5)
                XCTAssertGreaterThanOrEqual(Contrast.ratio(Palette.warning.hex(dark: dark), ground.hex(dark: dark)), 4.5)
            }
        }
    }

    func testKnownRatio() {
        XCTAssertEqual(Contrast.ratio(0x000000, 0xFFFFFF), 21, accuracy: 0.01)
    }
}
