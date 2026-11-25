import Carbon.HIToolbox
import XCTest
@testable import Splitroute

@MainActor
final class HotkeyTests: XCTestCase {
    func testLabelAndUsability() {
        let s = Shortcut(keyCode: 8, modifiers: UInt32(controlKey | optionKey | cmdKey), key: "c")
        XCTAssertEqual(s.label, "⌃⌥⌘C")
        XCTAssertTrue(s.isUsable)
        XCTAssertFalse(Shortcut(keyCode: 8, modifiers: UInt32(shiftKey), key: "c").isUsable, "shift alone is a capital letter")
        XCTAssertFalse(Shortcut(keyCode: 8, modifiers: 0, key: "c").isUsable, "a bare key would steal typing")
    }

    func testModifierBits() {
        XCTAssertEqual(Shortcut.carbon([.command, .shift]), UInt32(cmdKey | shiftKey))
        XCTAssertEqual(Shortcut.carbon([]), 0)
    }

    func testStoredShortcutRoundTrips() {
        let old = Shortcut.stored
        defer { Shortcut.store(old) }
        let s = Shortcut(keyCode: 9, modifiers: UInt32(cmdKey | optionKey), key: "v")
        Shortcut.store(s)
        XCTAssertEqual(Shortcut.stored, s)
        Shortcut.store(nil)
        XCTAssertNil(Shortcut.stored)
    }

    /// Carbon says no to a combination that is already registered, and the recorder keeps the old shortcut then.
    func testRegisteringTheSameCombinationTwiceIsRefused() {
        // F19 with all four modifiers: nothing real uses it.
        let s = Shortcut(keyCode: UInt32(kVK_F19), modifiers: UInt32(controlKey | optionKey | cmdKey | shiftKey), key: "F19")
        XCTAssertTrue(Hotkey.shared.register(s))
        defer { Hotkey.shared.register(nil) }
        // Another registration from this process under the same id replaces it; a second handler id would clash. The first one holds.
        XCTAssertTrue(Hotkey.shared.register(s), "re-registering the same shortcut replaces it")
        XCTAssertTrue(Hotkey.shared.register(nil))
    }
}
