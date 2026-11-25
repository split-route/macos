import Foundation
import Security

/// Decides whether a downloaded app may replace the running one: only if it is signed by the same certificate. The running
/// app's own designated requirement (its bundle ID plus its certificate's fingerprint) is the test, so there is no key
/// to ship inside the app and nothing to trust but the signer of the app already installed. An app signed ad hoc
/// has only a build hash for an identity: it can't be a signer to trust, so it never updates itself.
enum UpdateVerifier {
    struct Failure: LocalizedError {
        var errorDescription: String?
        init(_ m: String) { errorDescription = m }
    }

    /// The requirement a certificate signature gives: `identifier "x" and certificate leaf = H"…"`. An ad-hoc one is
    /// `cdhash H"…"`, which no other build satisfies.
    static func pinsCertificate(_ requirement: String) -> Bool {
        requirement.contains("certificate leaf = H\"") && !requirement.contains("cdhash")
    }

    /// The running app's designated requirement, as a requirement object and as text.
    static func runningRequirement() -> (requirement: SecRequirement, text: String)? {
        var me: SecCode?
        var staticMe: SecStaticCode?
        var req: SecRequirement?
        var text: CFString?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me,
              SecCodeCopyStaticCode(me, [], &staticMe) == errSecSuccess, let staticMe,
              SecCodeCopyDesignatedRequirement(staticMe, [], &req) == errSecSuccess, let req,
              SecRequirementCopyString(req, [], &text) == errSecSuccess, let text else { return nil }
        return (req, text as String)
    }

    /// Throws unless the app at `url` is validly signed (every file sealed, every architecture, nested code too) and
    /// satisfies `requirement`.
    static func verify(app url: URL, satisfies requirement: SecRequirement) throws {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else {
            throw Failure("The downloaded app can't be read.")
        }
        let flags = SecCSFlags(rawValue: UInt32(kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode))
        var error: Unmanaged<CFError>?
        guard SecStaticCodeCheckValidityWithErrors(code, flags, requirement, &error) == errSecSuccess else {
            let why = error?.takeRetainedValue().localizedDescription ?? "it doesn't match"
            throw Failure("The downloaded app isn't signed by the same certificate as this one (\(why)). It was not installed.")
        }
    }

    /// `verify` against the running app, which must itself be signed with a certificate.
    static func verifyAgainstRunning(app url: URL) throws {
        guard let running = runningRequirement(), pinsCertificate(running.text) else {
            throw Failure("This copy of Splitroute is signed ad hoc, so it can't check that an update is genuine. Install the update from the release page.")
        }
        try verify(app: url, satisfies: running.requirement)
    }
}
