import Foundation

/// Makes a .ovpn file self-contained: the service never opens paths from a
/// profile, so referenced files (ca, cert, key, tls-auth, …) are read here,
/// next to the profile, and put inline (<ca>…</ca>). The service then checks
/// the result like any other profile.
enum OvpnProfile {
    struct Result {
        var text: String
        /// From an `auth-user-pass <file>` line: the file's two lines.
        var credentials: (username: String, password: String)?
    }

    struct InlineError: LocalizedError {
        var errorDescription: String?
    }

    private static let textFiles: Set<String> = ["ca", "cert", "key", "dh", "tls-auth", "tls-crypt", "tls-crypt-v2",
                                                  "crl-verify", "extra-certs", "secret"]
    private static let maxFile = 1 << 20

    static func inline(_ text: String, directory: URL) throws -> Result {
        var out: [String] = []
        var result = Result(text: "")
        var block: String?
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces.union(.init(charactersIn: "\r")))
            if let b = block {
                out.append(line)
                if line == "</\(b)>" { block = nil }
                continue
            }
            if line.hasPrefix("<"), line.hasSuffix(">"), !line.hasPrefix("</"), line != "<connection>" {
                block = String(line.dropFirst().dropLast())
                out.append(line)
                continue
            }
            let args = tokens(line)
            guard let first = args.first, !line.hasPrefix("#"), !line.hasPrefix(";") else { out.append(line); continue }
            let d = String(first.drop(while: { $0 == "-" }))
            let rest = Array(args.dropFirst())
            switch d {
            case _ where textFiles.contains(d) && !rest.isEmpty && rest[0] != "[inline]":
                let body = try read(rest[0], directory)
                guard let s = String(data: body, encoding: .utf8) else {
                    throw InlineError(errorDescription: "\(rest[0]) isn't a text file.")
                }
                if d == "tls-auth", rest.count > 1 { out.append("key-direction \(rest[1])") }
                out.append("<\(d)>")
                out.append(s.trimmingCharacters(in: .whitespacesAndNewlines))
                out.append("</\(d)>")
            case "pkcs12" where !rest.isEmpty:
                let b64 = try read(rest[0], directory).base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
                out += ["<pkcs12>", b64, "</pkcs12>"]
            case "auth-user-pass" where !rest.isEmpty:
                let s = String(decoding: try read(rest[0], directory), as: UTF8.self)
                let lines = s.components(separatedBy: .newlines)
                if lines.count >= 2 { result.credentials = (lines[0], lines[1]) }
                out.append("auth-user-pass")
            default:
                out.append(line)
            }
        }
        result.text = out.joined(separator: "\n") + "\n"
        return result
    }

    private static func read(_ path: String, _ dir: URL) throws -> Data {
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : dir.appendingPathComponent(path)
        guard let data = try? Data(contentsOf: url) else {
            throw InlineError(errorDescription: "Can't read \(path). Keep the files the profile mentions next to it, or put them inline.")
        }
        guard data.count <= maxFile else { throw InlineError(errorDescription: "\(path) is larger than 1 MB.") }
        return data
    }

    /// Splits a config line on spaces, honoring quotes.
    static func tokens(_ line: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var quote: Character?
        var has = false
        for c in line {
            if let q = quote {
                if c == q { quote = nil } else { cur.append(c) }
            } else if c == "\"" || c == "'" {
                quote = c
                has = true
            } else if c == " " || c == "\t" {
                if has { out.append(cur); cur = ""; has = false }
            } else if (c == "#" || c == ";") && !has {
                break
            } else {
                cur.append(c)
                has = true
            }
        }
        if has { out.append(cur) }
        return out
    }

    // MARK: Server override

    /// A server as typed: "host", "host:port" or "[v6 address]:port". The port is nil when none was given.
    struct Server: Equatable {
        var host: String
        var port: Int?
    }

    /// Reads a server override, or says what is wrong with it. Empty is no override (nil).
    static func parseServer(_ spec: String) throws -> Server? {
        let s = spec.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }
        var host = s
        var port: Int?
        if s.hasPrefix("[") {
            guard let close = s.firstIndex(of: "]") else { throw InlineError(errorDescription: "\"\(s)\": a bracketed IPv6 address needs its closing ].") }
            host = String(s[s.index(after: s.startIndex)..<close])
            let rest = s[s.index(after: close)...]
            if !rest.isEmpty {
                guard rest.hasPrefix(":"), let p = Int(rest.dropFirst()) else { throw InlineError(errorDescription: "\"\(s)\": write [address]:port.") }
                port = p
            }
        } else if s.filter({ $0 == ":" }).count == 1, let c = s.firstIndex(of: ":") {
            host = String(s[..<c])
            guard let p = Int(s[s.index(after: c)...]) else { throw InlineError(errorDescription: "\"\(s)\": the port after the colon must be a number.") }
            port = p
        } // more than one colon without brackets is a bare IPv6 address
        if let p = port, !(1...65535).contains(p) { throw InlineError(errorDescription: "The port must be from 1 to 65535.") }
        var v6 = in6_addr()
        let isAddress = host.withCString { inet_pton(AF_INET6, $0, &v6) } == 1
        let name = try! NSRegularExpression(pattern: #"^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$"#)
        guard isAddress || name.firstMatch(in: host, range: NSRange(host.startIndex..., in: host)) != nil else {
            throw InlineError(errorDescription: "\"\(host)\" is not a host name or an address.")
        }
        return Server(host: host, port: port)
    }

    /// The profile with its `remote` lines replaced by the one server given, as OpenVPN's own app does it. The port and
    /// protocol of the profile's first remote are kept when the override has none of its own. The rest is untouched.
    static func overridingServer(_ profile: String, with spec: String) throws -> String {
        guard let server = try parseServer(spec) else { return profile }
        var out: [String] = []
        var first: [String]?
        var at: Int?
        var block: String?
        for raw in profile.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces.union(.init(charactersIn: "\r")))
            if let b = block {
                out.append(raw)
                if line == "</\(b)>" { block = nil }
                continue
            }
            if line.hasPrefix("<"), line.hasSuffix(">"), !line.hasPrefix("</"), line != "<connection>" {
                block = String(line.dropFirst().dropLast())
                out.append(raw)
                continue
            }
            let args = tokens(line)
            if args.first == "remote", !line.hasPrefix("#"), !line.hasPrefix(";") {
                if first == nil { first = Array(args.dropFirst()); at = out.count }
                continue // every remote is replaced by the one
            }
            out.append(raw)
        }
        guard let first else { throw InlineError(errorDescription: "The profile has no remote line to override.") }
        let port = server.port.map(String.init) ?? (first.count > 1 ? first[1] : "1194")
        var line = "remote \(server.host) \(port)"
        if first.count > 2 { line += " \(first[2])" }
        out.insert(line, at: at ?? 0)
        return out.joined(separator: "\n")
    }
}
