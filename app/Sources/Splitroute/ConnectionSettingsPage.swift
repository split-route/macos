import AppKit
import Design
import SwiftUI

/// A switch with no label of its own (the row carries the text).
func settingsSwitch(_ title: String, isOn: Binding<Bool>) -> some View {
    Toggle(title, isOn: isOn).labelsHidden().toggleStyle(.switch).tint(Accent.color)
}

/// Settings > Connection: how the connection is made and protected.
struct ConnectionSettingsPage: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage(Prefs.alwaysOn) private var alwaysOn = false
    @AppStorage(Prefs.disconnectOnSleep) private var disconnectOnSleep = false
    @AppStorage(Prefs.showDisconnectMessage) private var showMessage = false
    @AppStorage(Prefs.sortByPing) private var sortByPing = true
    @AppStorage(Prefs.testMethod) private var testMethod = TestMethod.connect.rawValue
    @AppStorage(Prefs.testTimeout) private var testTimeout = 5
    @AppStorage(Prefs.testInterval) private var testInterval = 600
    @AppStorage(Prefs.testURL) private var testURL = Prefs.defaultTestURL
    @AppStorage(Prefs.testCustomURL) private var testCustomURL = ""
    @State private var editingURL = false
    private static func fingerprintLabel(_ f: String) -> String {
        ["": "Automatic", "ios": "iOS", "android": "Android"][f] ?? f.prefix(1).uppercased() + f.dropFirst()
    }
    private static let bootstrapLabels = ["": "Automatic", "1.1.1.1": "Cloudflare (1.1.1.1)", "8.8.8.8": "Google (8.8.8.8)", "9.9.9.9": "Quad9 (9.9.9.9)", "system": "System resolver"]

    var body: some View {
        PageScaffold("Connection") {
            EmptyView()
        } content: {
            if model.status == nil { ServiceUnavailable() }
            if model.status != nil { connection; killSwitch; alwaysOnSection; testSection }
        }
    }

    private func toggle(_ title: String, isOn: Binding<Bool>) -> some View { settingsSwitch(title, isOn: isOn) }

    @ViewBuilder private var connection: some View {
        SectionTitle("Connection")
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

    // MARK: Kill switch

    @ViewBuilder private var killSwitch: some View {
        SectionTitle("Kill switch")
        Panel {
            FormRow("Block traffic if the connection drops",
                    detail: "While connected, only your servers' own connections can leave this Mac. If the server fails, the network stops instead of using your normal connection.",
                    error: model.error("killswitch")) {
                toggle("Block traffic if the connection drops", isOn: Binding(get: { model.killSwitchOn }, set: { on in Task { await model.setKillSwitch(on: on) } }))
                    .disabled(model.busy)
            }
            Hairline()
            FormRow("Allow the local network", detail: "Printers, file shares and your router stay reachable while traffic is blocked.") {
                toggle("Allow the local network", isOn: Binding(get: { model.killSwitchLAN }, set: { on in Task { await model.setKillSwitch(lan: on) } }))
                    .disabled(model.busy || !model.killSwitchOn)
            }
            Hairline()
            NoteLine(.warning, "Programs running as root can still reach the network. The kill switch also stays on after a restart: the network is blocked until the connection is up, so keep the app set to open at login. Uninstalling the service turns it off.")
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Space.l)
        }
    }

    // MARK: Always on

    @ViewBuilder private var alwaysOnSection: some View {
        SectionTitle("Always on")
        Panel {
            FormRow("Always on",
                    detail: "Connects when Splitroute opens and when the Mac wakes, if the connection is off. It works only while Splitroute is running, and a server that failed is not retried by itself. Turning the connection off keeps it off until the next launch or wake.") {
                settingsSwitch("Always on", isOn: Binding(get: { alwaysOn }, set: { on in alwaysOn = on; Task { await model.setAlwaysOn(on) } }))
            }
            Hairline()
            FormRow("Disconnect on sleep",
                    detail: model.killSwitchOn
                        ? "Off while the kill switch is on: disconnecting would block the whole network when the Mac wakes."
                        : "Disconnects when the Mac goes to sleep and connects again when it wakes.") {
                settingsSwitch("Disconnect on sleep", isOn: $disconnectOnSleep).disabled(model.killSwitchOn)
            }
            Hairline()
            FormRow("Show disconnect message", detail: "Posts a notification when it disconnects for sleep.") {
                settingsSwitch("Show disconnect message", isOn: Binding(get: { showMessage }, set: { showMessage = $0; model.setShowDisconnectMessage($0) }))
                    .disabled(!disconnectOnSleep || model.killSwitchOn)
            }
        }
    }

    // MARK: Test

    private var method: TestMethod { TestMethod(rawValue: testMethod) ?? .connect }

    @ViewBuilder private var testSection: some View {
        SectionTitle("Test")
        Panel {
            FormRow("Test method", detail: method.detail) {
                SelectMenu(title: method.title, options: TestMethod.allCases, label: { $0.title }, selected: method) { testMethod = $0.rawValue }
            }
            Hairline()
            FormRow("Timeout", detail: "Give up on a server that hasn't answered after this long.") {
                SelectMenu(title: "\(testTimeout) s", options: [1, 2, 3, 5, 10, 15, 30], label: { "\($0) s" }, selected: testTimeout) { testTimeout = $0 }
            }
            Hairline()
            FormRow("Keep results for", detail: "Results older than this are cleared, and the servers go back to their own order.") {
                SelectMenu(title: Self.seconds(testInterval), options: [60, 300, 600, 1800, 3600], label: Self.seconds, selected: testInterval) { testInterval = $0 }
            }
            if method == .connect {
                Hairline()
                FormRow("Test URL", detail: testURL) {
                    HStack(spacing: Space.s) {
                        SelectMenu(title: urlChoice, options: Self.urlChoices, label: { $0 }, selected: urlChoice) { c in
                            if let p = Prefs.testURLPresets.first(where: { $0.name == c }) { testURL = p.url } else { editingURL = true }
                        }
                        if urlChoice == Self.customChoice {
                            Button { editingURL = true } label: {
                                Image(systemName: "pencil").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.ink.color)
                                    .modifier(RoundGlass(size: 28))
                            }
                            .buttonStyle(.plain).help("Edit the test URL").accessibilityLabel("Edit the test URL")
                        }
                    }
                }
                .sheet(isPresented: $editingURL) {
                    TestURLSheet(current: urlChoice == Self.customChoice ? testURL : testCustomURL) { url in
                        testCustomURL = url
                        testURL = url
                    }
                    .glassSheet()
                }
            }
            Hairline()
            FormRow("Sort by ping", detail: "After a test, the fastest server comes first and the ones that didn't answer last. Only the display changes.") {
                settingsSwitch("Sort by ping", isOn: $sortByPing)
            }
        }
    }

    private static let customChoice = "Custom"
    private static let urlChoices = Prefs.testURLPresets.map(\.name) + [customChoice]
    /// The preset the saved address belongs to, or Custom.
    private var urlChoice: String { Prefs.testURLPresets.first { $0.url == testURL }?.name ?? Self.customChoice }

    private static func seconds(_ s: Int) -> String { s < 60 ? "\(s) s" : s % 60 == 0 && s < 3600 ? "\(s / 60) min" : s % 3600 == 0 ? "\(s / 3600) h" : "\(s) s" }
}

/// How a server is measured. TCP and ICMP time the server's own address, outside the tunnel; CONNECT times a request
/// through it.
enum TestMethod: String, CaseIterable {
    case tcp, icmp, connect

    var title: String { self == .connect ? "CONNECT" : rawValue.uppercased() }

    var detail: String {
        switch self {
        case .tcp: "Time to open a connection to the server's port. Servers that use UDP (WireGuard, Hysteria2, TUIC, OpenVPN over UDP) can't be measured."
        case .icmp: "Time for the server to answer a ping. Not available while the kill switch is on, and some servers don't answer pings."
        case .connect: "Test URL request via proxy server."
        }
    }
}

/// Asks for the custom test address and saves it only when it is a valid https address.
struct TestURLSheet: View {
    @Environment(\.dismiss) private var dismiss
    let current: String
    let save: (String) -> Void
    @State private var text = ""
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Space.s) {
                Text("Test URL").font(TypeScale.bodyStrong)
                TextField("Test URL", text: $text, prompt: Text("https://example.com/generate_204").foregroundColor(.secondary))
                    .labelsHidden().textFieldStyle(.plain).multilineTextAlignment(.leading).fieldBox().onSubmit(commit)
                Text("An https address that answers with a small body. It is requested through each server.")
                    .font(TypeScale.secondary).foregroundStyle(Palette.inkSecondary.color)
            }
            .padding(Space.xl)
            SheetButtons(error: error) {
                Button("Cancel", role: .cancel) { dismiss() }.buttonStyle(OutlineButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Save", action: commit).buttonStyle(SolidButtonStyle()).keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .frame(width: 440)
        .onAppear { text = current }
    }

    private func commit() {
        guard let ok = Prefs.validTestURL(text) else {
            error = "Enter an https address, like https://example.com/generate_204."
            return
        }
        save(ok)
        dismiss()
    }
}
