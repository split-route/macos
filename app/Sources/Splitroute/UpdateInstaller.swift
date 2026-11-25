import CryptoKit
import Foundation

/// Downloads a release of the app, proves it is ours, and swaps it in. Nothing here runs unless the user turned automatic
/// downloads on or pressed Download or Install. The proof is the signature: the new app must satisfy the running app's own
/// designated requirement (`UpdateVerifier`), and is checked again right before the swap.
enum UpdateInstaller {
    static let maxZip = 400 << 20
    static var root: URL { AppFiles.standard.root.appendingPathComponent("Updates", isDirectory: true) }

    static func directory(_ version: String) -> URL { root.appendingPathComponent(version, isDirectory: true) }
    static func stagedApp(_ version: String) -> URL { directory(version).appendingPathComponent("Splitroute.app", isDirectory: true) }

    /// Why this copy of the app can't update itself, or nil when it can.
    static func blockedReason(bundle: URL = Bundle.main.bundleURL) -> String? {
        if bundle.path.contains("/AppTranslocation/") { return "Move Splitroute to your Applications folder first." }
        if ["/opt/homebrew/Caskroom/splitroute", "/usr/local/Caskroom/splitroute"].contains(where: { FileManager.default.fileExists(atPath: $0) }) {
            return "Installed with Homebrew: run brew upgrade --cask splitroute."
        }
        if !FileManager.default.isWritableFile(atPath: bundle.deletingLastPathComponent().path) {
            return "Splitroute's folder isn't writable by you. Install the update from the release page."
        }
        guard let running = UpdateVerifier.runningRequirement(), UpdateVerifier.pinsCertificate(running.text) else {
            return "This copy is signed ad hoc, so it can't check that an update is genuine. Install it from the release page."
        }
        return nil
    }

    /// The staged versions on disk that are newer than `current`, newest first. Anything else is deleted.
    static func ready(current: String) -> String? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        var best: String?
        for n in names {
            let ok = AppUpdate.isNewer(n, than: current) && FileManager.default.fileExists(atPath: stagedApp(n).path)
            if !ok { try? FileManager.default.removeItem(at: directory(n)); continue }
            if best == nil || AppUpdate.isNewer(n, than: best!) { best = n }
        }
        for n in names where n != best { try? FileManager.default.removeItem(at: directory(n)) }
        return best
    }

    /// Downloads, checks and stages `release`. Returns the staged app. Anything that fails leaves nothing behind.
    static func download(_ release: AppUpdate.Release, progress: @escaping @Sendable (Double?) -> Void) async throws -> URL {
        guard let zipURL = release.zip, let shaURL = release.zipSHA256 else {
            throw StoreError("This release has no app archive to download. Get it from the release page.")
        }
        let dir = directory(release.version)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            let shaFile = try await Fetch.get(shaURL, limit: 4096)
            guard shaFile.status == 200, let want = AppUpdate.parseChecksum(String(decoding: shaFile.body, as: UTF8.self)) else {
                throw StoreError("The checksum of the update can't be read.")
            }
            let zip = dir.appendingPathComponent("Splitroute.zip")
            try await Fetch.downloadFile(zipURL, to: zip, limit: maxZip, progress: progress)
            guard try sha256(of: zip) == want else { throw StoreError("The download is damaged (its checksum doesn't match). Try again.") }
            let extract = dir.appendingPathComponent("extract", isDirectory: true)
            try await unzip(zip, into: extract)
            let items = try FileManager.default.contentsOfDirectory(atPath: extract.path).filter { !$0.hasPrefix(".") && $0 != "__MACOSX" }
            guard items == ["Splitroute.app"] else { throw StoreError("The archive doesn't hold just Splitroute.app.") }
            let app = extract.appendingPathComponent("Splitroute.app")
            try check(app, version: release.version)
            let staged = stagedApp(release.version)
            try FileManager.default.moveItem(at: app, to: staged)
            try? FileManager.default.removeItem(at: zip)
            try? FileManager.default.removeItem(at: extract)
            return staged
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
    }

    /// The app must be this app, at the version the release says, signed by the same certificate as the running one.
    static func check(_ app: URL, version: String) throws {
        let plist = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        guard plist?["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier else { throw StoreError("The downloaded app is not Splitroute.") }
        guard plist?["CFBundleShortVersionString"] as? String == version else { throw StoreError("The downloaded app is not version \(version).") }
        try UpdateVerifier.verifyAgainstRunning(app: app)
    }

    static func sha256(of file: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: file)
        defer { try? h.close() }
        var hash = SHA256()
        while let chunk = try h.read(upToCount: 1 << 20), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// `ditto` keeps what a zip of an app must keep (the signature's seal, symlinks, extended attributes).
    private static func unzip(_ zip: URL, into dir: URL) async throws {
        try await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            p.arguments = ["-x", "-k", zip.path, dir.path]
            let err = Pipe()
            p.standardError = err
            try p.run()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { throw StoreError("The archive can't be opened.") }
        }.value
    }

    /// The script that swaps the app once this process has quit: it keeps the old app until the new one is in place, puts it
    /// back if anything fails, and opens whichever is there. Its arguments are paths, never spliced into the text.
    static let swapScript = """
    #!/bin/sh
    pid=$1; new=$2; dest=$3; work=$4
    i=0
    while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 60 ]; do sleep 0.5; i=$((i+1)); done
    if kill -0 "$pid" 2>/dev/null; then exit 1; fi
    parent=$(dirname "$dest")
    tmp="$parent/.Splitroute.new.$$"
    old="$parent/.Splitroute.old.$$"
    if ! /usr/bin/ditto "$new" "$tmp"; then rm -rf "$tmp"; /usr/bin/open "$dest"; exit 1; fi
    if ! mv "$dest" "$old"; then rm -rf "$tmp"; /usr/bin/open "$dest"; exit 1; fi
    if mv "$tmp" "$dest"; then rm -rf "$old" "$work"; else mv "$old" "$dest"; rm -rf "$tmp"; fi
    /usr/bin/open "$dest"
    """

    /// Checks the staged app once more, then starts the swap. The caller quits right after: the script waits for that.
    static func install(version: String, current: String, bundle: URL = Bundle.main.bundleURL) throws {
        if let why = blockedReason(bundle: bundle) { throw StoreError(why) }
        let app = stagedApp(version)
        try check(app, version: version)
        guard AppUpdate.isNewer(version, than: current) else { throw StoreError("That is not a newer version.") }
        let script = directory(version).appendingPathComponent("swap.sh")
        try Data(swapScript.utf8).write(to: script, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/nohup")
        p.arguments = ["/bin/sh", script.path, String(ProcessInfo.processInfo.processIdentifier), app.path, bundle.path, directory(version).path]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
    }
}
