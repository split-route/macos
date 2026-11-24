import Foundation

/// Downloads for the app: release lists, imports and subscriptions. The service never fetches anything. https only,
/// redirects only to https, no cookies, 60 s per request, and a body over its limit is an error, never
/// truncated: a cut-off list would silently lose entries.
enum Fetch {
    static let userAgent = "splitroute/" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")
    static let maxList = 64 << 20          // imports and release files
    static let maxSubscription = 8 << 20   // a subscription body is a few hundred KB at most

    /// Redirects only to https without credentials (URLSession stops long chains itself).
    private final class HTTPSOnly: NSObject, URLSessionTaskDelegate {
        func urlSession(_ s: URLSession, task: URLSessionTask, willPerformHTTPRedirection r: HTTPURLResponse, newRequest req: URLRequest,
                        completionHandler done: @escaping (URLRequest?) -> Void) {
            done(req.url?.scheme == "https" && req.url?.user == nil ? req : nil)
        }
    }

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.timeoutIntervalForRequest = 60
        c.timeoutIntervalForResource = 60
        c.urlCache = nil
        return URLSession(configuration: c, delegate: HTTPSOnly(), delegateQueue: nil)
    }()

    struct Response { var status: Int; var body: Data; var headers: [String: String] }

    /// Where one list's download is: a fraction (nil when the server didn't say the size) or the reason it failed.
    enum DownloadState: Equatable, Sendable { case running(Double?), failed(String) }
    /// Reports a list's state; nil means it finished.
    typealias DownloadReport = @Sendable (String, DownloadState?) -> Void

    /// One GET. `host` names the server in errors instead of the address: a subscription's address carries a token.
    static func get(_ url: URL, headers: [String: String] = [:], limit: Int, progress: (@Sendable (Double?) -> Void)? = nil) async throws -> Response {
        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let host = url.host ?? "the server"
        let (bytes, resp): (URLSession.AsyncBytes, URLResponse)
        do { (bytes, resp) = try await session.bytes(for: req) } catch {
            throw StoreError("Could not download from \(host): \((error as NSError).localizedDescription)")
        }
        guard let http = resp as? HTTPURLResponse else { throw StoreError("\(host) did not answer with HTTP.") }
        var h: [String: String] = [:]
        for (k, v) in http.allHeaderFields { if let k = k as? String, let v = v as? String { h[k.lowercased()] = v } }
        guard http.statusCode == 200 else { return Response(status: http.statusCode, body: Data(), headers: h) }
        var body = Data()
        let total = http.expectedContentLength // -1 when unknown
        var reported = 0
        do {
            for try await b in bytes {
                body.append(b)
                if let progress, body.count - reported >= 16 << 10 {
                    reported = body.count
                    progress(total > 0 ? min(Double(body.count) / Double(total), 1) : nil)
                }
                if body.count > limit { throw StoreError("The answer from \(host) is larger than \(limit >> 20) MB.") }
            }
        } catch let e as StoreError { throw e } catch {
            throw StoreError("Could not read the answer from \(host): \((error as NSError).localizedDescription)")
        }
        return Response(status: 200, body: body, headers: h)
    }

    // MARK: Subscriptions

    /// A subscription's address carries the user's token: https, no user name or password.
    static func checkSubscriptionURL(_ raw: String) throws -> URL {
        guard let u = URL(string: raw), let host = u.host, !host.isEmpty, u.scheme != nil else { throw StoreError("That is not a web address.") }
        guard u.scheme == "https" else { throw StoreError("Subscriptions must use https:// (the address carries your token).") }
        guard u.user == nil, u.password == nil else { throw StoreError("Put the token in the address path or query, not as a user name and password.") }
        return u
    }

    static func looksLikeURL(_ s: String) -> Bool {
        !s.contains(where: \.isWhitespace) && (s.hasPrefix("https://") || s.hasPrefix("http://"))
    }

    /// Downloads a subscription body. Errors name the host and never the rest of the address.
    static func subscription(_ url: URL) async throws -> (body: String, usage: SubscriptionUsage?) {
        // Panels pick the format by User-Agent: a generic one gets the link list.
        let r = try await get(url, limit: maxSubscription)
        let host = url.host ?? "the server"
        guard r.status == 200 else { throw StoreError("\(host) answered HTTP \(r.status).") }
        guard let text = String(data: r.body, encoding: .utf8) else { throw StoreError("\(host) did not return text.") }
        return (text, parseUserinfo(r.headers["subscription-userinfo"] ?? ""))
    }

    /// The Subscription-Userinfo header panels send: "upload=0; download=204300000000; total=400000000000; expire=1780000000".
    /// Nil when there is no usable download or total; bad or negative numbers are ignored.
    static func parseUserinfo(_ h: String) -> SubscriptionUsage? {
        var u = SubscriptionUsage(upload: 0, download: 0, total: nil, expire: nil)
        var seen = false
        for part in h.split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard kv.count == 2, let n = Int64(kv[1]), n >= 0 else { continue }
            switch kv[0].lowercased() {
            case "upload": u.upload = n; seen = true
            case "download": u.download = n; seen = true
            case "total": u.total = n; seen = true
            case "expire": u.expire = n
            default: break
            }
        }
        return seen ? u : nil
    }

    // MARK: Imports

    struct Imported { var body: Data; var etag: String; var lastModified: String; var notModified: Bool }

    /// Downloads an import, conditionally on the validators of the last good copy.
    static func importList(_ url: URL, etag: String, lastModified: String, progress: (@Sendable (Double?) -> Void)? = nil) async throws -> Imported {
        var h: [String: String] = [:]
        if !etag.isEmpty { h["If-None-Match"] = etag }
        if !lastModified.isEmpty { h["If-Modified-Since"] = lastModified }
        let r = try await get(url, headers: h, limit: maxList, progress: progress)
        let tag = r.headers["etag"] ?? "", mod = r.headers["last-modified"] ?? ""
        switch r.status {
        case 304: return Imported(body: Data(), etag: tag, lastModified: mod, notModified: true)
        case 200: return Imported(body: r.body, etag: tag, lastModified: mod, notModified: false)
        default: throw StoreError("\(url.host ?? "The server") answered HTTP \(r.status).")
        }
    }

    // MARK: Release lists

    static func parseSums(_ text: String) -> [String: String] {
        var m: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let f = line.split(whereSeparator: \.isWhitespace)
            if f.count == 2 { m[String(f[1].drop { $0 == "*" })] = String(f[0]) }
        }
        return m
    }

    private static func releaseURL(_ base: String, _ file: String) throws -> URL {
        guard let u = URL(string: base + "/" + file) else { throw StoreError("The release address is not valid.") }
        return u
    }

    /// The list names in the release at `base`.
    static func releaseNames(_ base: String) async throws -> [String] {
        let r = try await get(try releaseURL(base, "SHA256SUMS"), limit: 1 << 20)
        guard r.status == 200 else { throw StoreError("The release answered HTTP \(r.status).") }
        let sums = parseSums(String(decoding: r.body, as: UTF8.self))
        return sums.keys.compactMap { $0.hasSuffix(".list") ? String($0.dropLast(5)) : nil }.sorted()
    }

    /// Downloads each named list and checks it against the release's SHA256SUMS. A list that can't be downloaded or
    /// verified keeps the last verified copy in `files`, so a network hiccup never drops routes. Returns the lists that
    /// were replaced and a warning for each that wasn't.
    static func releaseLists(_ base: String, names: [String], files: AppFiles, report: DownloadReport? = nil) async -> (replaced: Set<String>, warnings: [String]) {
        guard !names.isEmpty else { return ([], []) }
        var warnings: [String] = []
        var sums: [String: String]?
        do {
            let r = try await get(try releaseURL(base, "SHA256SUMS"), limit: 1 << 20)
            if r.status == 200 { sums = parseSums(String(decoding: r.body, as: UTF8.self)) } else { warnings.append("SHA256SUMS: HTTP \(r.status)") }
        } catch { warnings.append("SHA256SUMS: \(error.localizedDescription)") }
        var replaced = Set<String>()
        for n in names {
            let file = n + ".list"
            var why: String
            if let sums {
                if let want = sums[file] {
                    do {
                        let r = try await get(try releaseURL(base, file), limit: maxList) { report?(n, .running($0)) }
                        if r.status != 200 { why = "HTTP \(r.status)" }
                        else if AppFiles.sha256(r.body) != want { why = "checksum mismatch" }
                        else {
                            try files.writeRelease(n, r.body)
                            replaced.insert(n)
                            report?(n, nil)
                            continue
                        }
                    } catch { why = error.localizedDescription }
                } else { why = "not in this release" }
            } else { why = "no checksums" }
            report?(n, .failed(why))
            warnings.append("\(file): \(why)" + (files.releaseText(n) != nil ? "; using the saved copy" : "; no saved copy"))
        }
        return (replaced, warnings)
    }
}
