import Foundation

/// Looks for a newer release of the app on GitHub. Only the version and the release page come back: nothing is
/// downloaded or installed, the user does that from the page.
enum AppUpdate {
    static let latestURL = URL(string: "https://api.github.com/repos/split-route/macos/releases/latest")!
    static let releasesPage = URL(string: "https://github.com/split-route/macos/releases")!

    struct Release: Equatable, Codable {
        var version: String // "0.4.0", no leading v
        var page: URL
        /// The zipped app and its checksum, when the release has them (older ones don't: they are installed by hand).
        var zip: URL?
        var zipSHA256: URL?
    }

    static func zipName(_ version: String) -> String { "Splitroute_\(version)_macos.zip" }

    /// A release asset's address: https on this project's GitHub releases only.
    static func assetURL(_ s: String?) -> URL? {
        guard let s, let u = URL(string: s), u.scheme == "https", u.host == "github.com", u.user == nil,
              u.path.hasPrefix("/split-route/macos/releases/download/") else { return nil }
        return u
    }

    /// The checksum a `shasum -a 256` file holds: the first 64 hex characters.
    static func parseChecksum(_ text: String) -> String? {
        let h = text.split(whereSeparator: \.isWhitespace).first.map(String.init)?.lowercased() ?? ""
        return h.count == 64 && h.allSatisfy(\.isHexDigit) ? h : nil
    }

    /// The release's version and page. The page must be on this project's GitHub; anything else falls back to the releases page.
    static func parse(_ data: Data) throws -> Release {
        struct Asset: Decodable { var name: String; var browser_download_url: String? }
        struct Body: Decodable { var tag_name: String; var html_url: String?; var draft: Bool?; var prerelease: Bool?; var assets: [Asset]? }
        let b = try JSONDecoder().decode(Body.self, from: data)
        let v = b.tag_name.hasPrefix("v") ? String(b.tag_name.dropFirst()) : b.tag_name
        guard !v.isEmpty, v.count <= 32, b.draft != true, b.prerelease != true else { throw StoreError("There is no release to compare with.") }
        var page = releasesPage
        if let s = b.html_url, let u = URL(string: s), u.scheme == "https", u.host == "github.com", u.path.hasPrefix("/split-route/macos/") { page = u }
        let assets = b.assets ?? []
        let zip = assets.first { $0.name == zipName(v) }.flatMap { assetURL($0.browser_download_url) }
        let sha = assets.first { $0.name == zipName(v) + ".sha256" }.flatMap { assetURL($0.browser_download_url) }
        return Release(version: v, page: page, zip: zip, zipSHA256: zip == nil ? nil : sha)
    }

    /// Whether `latest` is a higher version than `current`, comparing dotted numbers ("0.10.0" > "0.9.2"). A current version
    /// that isn't numbers (a development build) is never told to update.
    static func isNewer(_ latest: String, than current: String) -> Bool {
        func parts(_ s: String) -> [Int]? {
            let p = s.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
            return p.contains(nil) || p.isEmpty ? nil : p.map { $0! }
        }
        guard let l = parts(latest), let c = parts(current) else { return false }
        for i in 0..<max(l.count, c.count) {
            let (a, b) = (i < l.count ? l[i] : 0, i < c.count ? c[i] : 0)
            if a != b { return a > b }
        }
        return false
    }

    static func fetchLatest() async throws -> Release {
        let r = try await Fetch.get(latestURL, headers: ["Accept": "application/vnd.github+json"], limit: 1 << 20)
        guard r.status == 200 else { throw StoreError("GitHub answered HTTP \(r.status).") }
        return try parse(r.body)
    }
}
