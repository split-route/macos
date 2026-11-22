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
}
