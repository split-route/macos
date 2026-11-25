import XCTest
@testable import Splitroute

final class AppUpdateTests: XCTestCase {
    func testIsNewer() {
        let cases: [(String, String, Bool)] = [
            ("0.4.1", "0.4.0", true), ("0.4.0", "0.4.0", false), ("0.3.9", "0.4.0", false),
            ("0.10.0", "0.9.2", true), ("1.0", "0.9.9", true), ("0.4", "0.4.0", false),
            ("0.4.0", "dev", false), ("0.4.0", "", false), ("junk", "0.4.0", false),
        ]
        for (l, c, want) in cases { XCTAssertEqual(AppUpdate.isNewer(l, than: c), want, "\(l) vs \(c)") }
    }

    /// Fields copied from GET /repos/split-route/macos/releases/latest.
    func testParsesTheReleaseAnswer() throws {
        let body = #"{"draft":false,"html_url":"https://github.com/split-route/macos/releases/tag/v0.4.0","prerelease":false,"tag_name":"v0.4.0"}"#
        let r = try AppUpdate.parse(Data(body.utf8))
        XCTAssertEqual(r.version, "0.4.0")
        XCTAssertEqual(r.page.absoluteString, "https://github.com/split-route/macos/releases/tag/v0.4.0")
    }

    func testAPageOutsideTheProjectIsReplaced() throws {
        let body = #"{"html_url":"https://evil.example/x","tag_name":"v9.9.9"}"#
        XCTAssertEqual(try AppUpdate.parse(Data(body.utf8)).page, AppUpdate.releasesPage)
    }

    func testDraftsAndPreReleasesAreRefused() {
        XCTAssertThrowsError(try AppUpdate.parse(Data(#"{"tag_name":"v1.0.0","draft":true}"#.utf8)))
        XCTAssertThrowsError(try AppUpdate.parse(Data(#"{"tag_name":"v1.0.0","prerelease":true}"#.utf8)))
    }
}

/// The swap script, run for real on temporary folders (with `open` replaced by a stub that records the call).
final class SwapScriptTests: XCTestCase {
    var dir: URL!
    override func setUp() { dir = FileManager.default.temporaryDirectory.appendingPathComponent("swap-\(UUID().uuidString)") }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func app(_ name: String, marker: String) throws -> URL {
        let u = dir.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: u.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try marker.write(to: u.appendingPathComponent("Contents/marker"), atomically: true, encoding: .utf8)
        return u
    }

    private func run(new: URL, dest: URL, work: URL, pid: Int32) throws -> String {
        let log = dir.appendingPathComponent("opened.log")
        let script = dir.appendingPathComponent("swap.sh")
        let stubbed = UpdateInstaller.swapScript.replacingOccurrences(of: "/usr/bin/open", with: "echo >> '\(log.path)'")
        try Data(stubbed.utf8).write(to: script)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [script.path, String(pid), new.path, dest.path, work.path]
        try p.run()
        p.waitUntilExit()
        return (try? String(contentsOf: log, encoding: .utf8)) ?? ""
    }

    private func marker(_ app: URL) -> String? { try? String(contentsOf: app.appendingPathComponent("Contents/marker"), encoding: .utf8) }

    func testSwapsInTheNewAppAndCleansUp() throws {
        let dest = try app("Splitroute.app", marker: "old")
        let work = dir.appendingPathComponent("work", isDirectory: true)
        let new = try app("work/Splitroute.app", marker: "new")
        let opened = try run(new: new, dest: dest, work: work, pid: 999_999) // no such process: already quit
        XCTAssertEqual(marker(dest), "new")
        XCTAssertFalse(FileManager.default.fileExists(atPath: work.path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: dir.path).contains { $0.hasPrefix(".Splitroute.") }, "no leftovers")
        XCTAssertFalse(opened.isEmpty, "it opens the app afterwards")
    }

    func testKeepsTheOldAppWhenTheNewOneCannotBeCopied() throws {
        let dest = try app("Splitroute.app", marker: "old")
        let work = dir.appendingPathComponent("work", isDirectory: true)
        let opened = try run(new: dir.appendingPathComponent("missing.app"), dest: dest, work: work, pid: 999_999)
        XCTAssertEqual(marker(dest), "old")
        XCTAssertFalse(opened.isEmpty, "it still opens the old app")
    }

    func testDoesNothingWhileTheAppIsStillRunning() throws {
        let dest = try app("Splitroute.app", marker: "old")
        let new = try app("work/Splitroute.app", marker: "new")
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["60"]
        try sleeper.run()
        defer { sleeper.terminate() }
        // A short wait instead of the script's 30 s: the same loop, fewer rounds.
        let log = dir.appendingPathComponent("opened.log")
        let script = dir.appendingPathComponent("swap.sh")
        let quick = UpdateInstaller.swapScript.replacingOccurrences(of: "-lt 60", with: "-lt 2").replacingOccurrences(of: "/usr/bin/open", with: "echo >> '\(log.path)'")
        try Data(quick.utf8).write(to: script)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [script.path, String(sleeper.processIdentifier), new.path, dest.path, dir.path]
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 1)
        XCTAssertEqual(marker(dest), "old")
    }
}

final class UpdateAssetTests: XCTestCase {
    /// Asset fields copied from GET /repos/split-route/macos/releases/latest (v0.4.0; the zip names are the ones the release workflow will publish).
    func testFindsTheZipAndItsChecksum() throws {
        let base = "https://github.com/split-route/macos/releases/download/v0.5.0/"
        let body = """
        {"tag_name":"v0.5.0","html_url":"https://github.com/split-route/macos/releases/tag/v0.5.0","assets":[
        {"name":"Splitroute_0.5.0_macos.dmg","browser_download_url":"\(base)Splitroute_0.5.0_macos.dmg"},
        {"name":"Splitroute_0.5.0_macos.zip","browser_download_url":"\(base)Splitroute_0.5.0_macos.zip"},
        {"name":"Splitroute_0.5.0_macos.zip.sha256","browser_download_url":"\(base)Splitroute_0.5.0_macos.zip.sha256"}]}
        """
        let r = try AppUpdate.parse(Data(body.utf8))
        XCTAssertEqual(r.zip?.absoluteString, base + "Splitroute_0.5.0_macos.zip")
        XCTAssertEqual(r.zipSHA256?.absoluteString, base + "Splitroute_0.5.0_macos.zip.sha256")
    }

    func testAReleaseWithoutAZipHasNothingToDownload() throws {
        let body = #"{"tag_name":"v0.4.0","assets":[{"name":"Splitroute_0.4.0_macos.dmg","browser_download_url":"https://github.com/split-route/macos/releases/download/v0.4.0/Splitroute_0.4.0_macos.dmg"}]}"#
        let r = try AppUpdate.parse(Data(body.utf8))
        XCTAssertNil(r.zip)
        XCTAssertNil(r.zipSHA256)
    }

    func testAssetAddressesOutsideTheProjectAreIgnored() {
        for bad in ["http://github.com/split-route/macos/releases/download/v1/x.zip", "https://evil.example/split-route/macos/releases/download/v1/x.zip",
                    "https://github.com/other/repo/releases/download/v1/x.zip", "https://u:p@github.com/split-route/macos/releases/download/v1/x.zip"] {
            XCTAssertNil(AppUpdate.assetURL(bad), bad)
        }
    }

    func testChecksumFile() {
        let h = String(repeating: "ab", count: 32)
        XCTAssertEqual(AppUpdate.parseChecksum("\(h)  Splitroute_0.4.0_macos.dmg\n"), h)
        XCTAssertEqual(AppUpdate.parseChecksum(h.uppercased()), h)
        XCTAssertNil(AppUpdate.parseChecksum("nothex"))
        XCTAssertNil(AppUpdate.parseChecksum(String(h.dropLast())))
    }

    func testOnlyACertificateSignatureCanBeTrusted() {
        XCTAssertTrue(UpdateVerifier.pinsCertificate("identifier \"io.github.aliraghebi.splitroute.app\" and certificate leaf = H\"797110e2553b2b17618ae782607db5e83da0fb53\""))
        XCTAssertFalse(UpdateVerifier.pinsCertificate("cdhash H\"406fd656d6b7a989065d8a94781152548e98e895\""))
        XCTAssertFalse(UpdateVerifier.pinsCertificate("identifier \"x\" and anchor apple"))
    }
}
