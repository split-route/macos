import AppKit
import Design
import SwiftUI

/// Settings > Advanced: how servers are found and what the engine does with browser traffic. The defaults are safe; this
/// page is for when a network or a site needs something else.
struct AdvancedSettingsPage: View {
    @EnvironmentObject private var model: AppModel

    private static func fingerprintLabel(_ f: String) -> String {
        ["": "Automatic", "ios": "iOS", "android": "Android"][f] ?? f.prefix(1).uppercased() + f.dropFirst()
    }
    private static let bootstrapLabels = ["": "Automatic", "1.1.1.1": "Cloudflare (1.1.1.1)", "8.8.8.8": "Google (8.8.8.8)", "9.9.9.9": "Quad9 (9.9.9.9)", "system": "System resolver"]

    var body: some View {
        PageScaffold("Advanced") {
            EmptyView()
        } content: {
            if model.status == nil { ServiceUnavailable() }
            if model.status != nil { connection }
        }
    }

    private func toggle(_ title: String, isOn: Binding<Bool>) -> some View { settingsSwitch(title, isOn: isOn) }

    @ViewBuilder private var connection: some View {
        SectionTitle("Engine")
        Panel {
            FormRow("Find servers with",
                    detail: "Automatic asks Cloudflare, Google and Quad9 when you connect and uses the first that answers from your network, because networks block different ones. Pick one yourself if a server still fails with \"connection reset by peer\" or times out. The system resolver can return a blocked network's fake address.",
                    error: model.error("bootstrap")) {
                SelectMenu(title: Self.bootstrapLabels[model.bootstrap] ?? model.bootstrap, options: ["", "1.1.1.1", "8.8.8.8", "9.9.9.9", "system"],
                           label: { Self.bootstrapLabels[$0] ?? $0 }, selected: model.bootstrap) { v in Task { await model.setBootstrap(v) } }
                    .disabled(model.busy)
            }
            Hairline()
            FormRow("Block QUIC (HTTP/3)",
                    detail: "A browser can hide a site's name inside QUIC, so a Block list misses it. With this on, QUIC that no list matched is refused and the browser uses regular HTTPS, where the name is visible.",
                    error: model.error("blockQUIC")) {
                toggle("Block QUIC", isOn: Binding(get: { model.config?.blockQUIC ?? true },
                                                   set: { on in Task { await model.setBlockQUIC(on) } }))
            }
            Hairline()
            FormRow("Block STUN (WebRTC)",
                    detail: "A browser uses STUN to learn your public address. With some traffic going direct and some through a server, it can show the real one. With this on, STUN is refused, so video calls in the browser may need a TURN server.",
                    error: model.error("blockSTUN")) {
                toggle("Block STUN", isOn: Binding(get: { model.config?.blockSTUN ?? true },
                                                   set: { on in Task { await model.setBlockSTUN(on) } }))
            }
            Hairline()
            FormRow("TLS fingerprint",
                    detail: "Makes servers that use TLS (VLESS, VMess, Trojan) look like this browser to a network that inspects handshakes. A server whose link names a fingerprint keeps it. Automatic leaves every server as it is.",
                    error: model.error("tlsFingerprint")) {
                SelectMenu(title: Self.fingerprintLabel(model.config?.tlsFingerprint ?? ""), options: [""] + Config.tlsFingerprints,
                           label: Self.fingerprintLabel, selected: model.config?.tlsFingerprint ?? "") { v in Task { await model.setTLSFingerprint(v) } }
                    .disabled(model.busy)
            }
        }
    }
}
