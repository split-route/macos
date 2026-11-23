import CryptoKit
import Foundation

/// Where the app keeps its state: `~/Library/Application Support/Splitroute` (0700). The database holds metadata; what a
/// tunnel runs (a profile with keys, a link's options with its password) and a subscription's address (it carries the
/// user's token) are separate 0600 files, hash-checked before they go to the service. Credentials live in the Keychain.
struct AppFiles {
    let root: URL

    static var standard: AppFiles {
        #if DEBUG
        if let p = ProcessInfo.processInfo.environment["SPLITROUTE_HOME"] { return AppFiles(root: URL(fileURLWithPath: p)) }
        #endif
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return AppFiles(root: base.appendingPathComponent("Splitroute"))
    }

    var databasePath: String { root.appendingPathComponent("splitroute.db").path }

    private func dir(_ parts: String...) -> URL { parts.reduce(root) { $0.appendingPathComponent($1) } }

    /// Writes `data` to `url` as a 0600 file, replacing it whole (a crash never leaves half of it), in 0700 directories.
    func writePrivate(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let tmp = url.appendingPathExtension("tmp")
        try? fm.removeItem(at: tmp)
        guard fm.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw StoreError("Can't write \(url.lastPathComponent).")
        }
        _ = try fm.replaceItemAt(url, withItemAt: tmp)
    }

    // MARK: Tunnels

    func tunnelFile(_ t: StoreTunnel) -> URL {
        dir("tunnels", String(t.id)).appendingPathComponent(t.isOpenVPN ? "profile.ovpn" : "options.json")
    }

    static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    func writeTunnelSource(_ t: StoreTunnel, _ data: Data) throws { try writePrivate(data, to: tunnelFile(t)) }

    /// What a tunnel runs, checked against the hash stored at import: a file changed on disk is refused.
    func tunnelSource(_ t: StoreTunnel) throws -> Data {
        guard let data = try? Data(contentsOf: tunnelFile(t)) else {
            throw StoreError("The saved \(t.isOpenVPN ? "profile" : "options") of this tunnel can't be read. Import it again.")
        }
        guard AppFiles.sha256(data) == t.sha else { throw StoreError("The saved \(t.isOpenVPN ? "profile" : "options") changed since it was imported. Import it again.") }
        return data
    }

    func removeTunnelFiles(_ id: Int64) { try? FileManager.default.removeItem(at: dir("tunnels", String(id))) }

    // MARK: Subscriptions

    func subscriptionURLFile(_ id: Int64) -> URL { dir("subscriptions", String(id)).appendingPathComponent("url") }
    func subscriptionInfoFile(_ id: Int64) -> URL { dir("subscriptions", String(id)).appendingPathComponent("info.json") }

    func subscriptionURL(_ id: Int64) -> String? {
        (try? String(contentsOf: subscriptionURLFile(id), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func writeSubscriptionURL(_ id: Int64, _ url: String) throws { try writePrivate(Data(url.utf8), to: subscriptionURLFile(id)) }

    func removeSubscriptionFiles(_ id: Int64) { try? FileManager.default.removeItem(at: dir("subscriptions", String(id))) }

    /// What the provider reported with the last download; a new report replaces the old, and none removes it so a stale
    /// number is never shown.
    func saveUsage(_ id: Int64, _ u: SubscriptionUsage?) {
        guard let u else { try? FileManager.default.removeItem(at: subscriptionInfoFile(id)); return }
        guard let data = try? JSONEncoder().encode(u) else { return }
        try? writePrivate(data, to: subscriptionInfoFile(id))
    }

    func loadUsage(_ id: Int64) -> SubscriptionUsage? {
        guard let data = try? Data(contentsOf: subscriptionInfoFile(id)) else { return nil }
        return try? JSONDecoder().decode(SubscriptionUsage.self, from: data)
    }

    // MARK: Release lists

    func releaseFile(_ name: String) -> URL { dir("lists").appendingPathComponent(name + ".list") }

    func releaseText(_ name: String) -> String? { try? String(contentsOf: releaseFile(name), encoding: .utf8) }

    func writeRelease(_ name: String, _ data: Data) throws { try writePrivate(data, to: releaseFile(name)) }
}
