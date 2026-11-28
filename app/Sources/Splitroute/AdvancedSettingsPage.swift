import AppKit
import Design
import SwiftUI

/// Settings > Advanced: leaks and browser traffic, how servers are found, and how they are tested. The defaults are safe; this
/// page is for when a network or a site needs something else.
struct AdvancedSettingsPage: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage(Prefs.testMethod) private var testMethod = TestMethod.connect.rawValue
    @AppStorage(Prefs.testTimeout) private var testTimeout = 5
    @AppStorage(Prefs.testURL) private var testURL = Prefs.defaultTestURL
    @AppStorage(Prefs.testCustomURL) private var testCustomURL = ""
    @State private var editingURL = false

    private static func fingerprintLabel(_ f: String) -> String {
        ["": "Automatic", "ios": "iOS", "android": "Android"][f] ?? f.prefix(1).uppercased() + f.dropFirst()
    }
    private static let bootstrapLabels = ["": "Automatic", "1.1.1.1": "Cloudflare (1.1.1.1)", "8.8.8.8": "Google (8.8.8.8)", "9.9.9.9": "Quad9 (9.9.9.9)", "system": "System resolver"]

    var body: some View {
        SettingsPage("Advanced") {
            if model.status == nil { ServiceUnavailable() }
            if model.status != nil { traffic; engine; testSection }
        }
    }

    private func toggle(_ title: String, isOn: Binding<Bool>) -> some View { settingsSwitch(title, isOn: isOn) }

    @ViewBuilder private var traffic: some View {
        SettingsSection("Traffic") {
            FormRow("Block IPv6", detail: "Stops IPv6 from going around the tunnel and showing your real address.", error: model.error("blockIPv6")) {
                toggle("Block IPv6", isOn: Binding(get: { model.config?.blockIPv6 ?? true }, set: { on in Task { await model.setBlockIPv6(on) } }))
            }
            Hairline()
            FormRow("Block STUN (WebRTC)", detail: "Hides your real IP from browsers. May break calls.", error: model.error("blockSTUN")) {
                toggle("Block STUN", isOn: Binding(get: { model.config?.blockSTUN ?? false },
                                                   set: { on in Task { await model.setBlockSTUN(on) } }))
            }
            Hairline()
            FormRow("Block QUIC (HTTP/3)", detail: "Browsers fall back to HTTPS, so lists match names.", error: model.error("blockQUIC")) {
                toggle("Block QUIC", isOn: Binding(get: { model.config?.blockQUIC ?? false },
                                                   set: { on in Task { await model.setBlockQUIC(on) } }))
            }
        }
    }

    @ViewBuilder private var engine: some View {
        SettingsSection("Server access") {
            FormRow("Find servers with", detail: "How server names are looked up. Change it if servers fail with \"connection reset\".", error: model.error("bootstrap")) {
                SelectMenu(title: Self.bootstrapLabels[model.bootstrap] ?? model.bootstrap, options: ["", "1.1.1.1", "8.8.8.8", "9.9.9.9", "system"],
                           label: { Self.bootstrapLabels[$0] ?? $0 }, selected: model.bootstrap) { v in Task { await model.setBootstrap(v) } }
                    .disabled(model.busy)
            }
            Hairline()
            FormRow("TLS fingerprint", detail: "Make TLS servers look like a browser.", error: model.error("tlsFingerprint")) {
                SelectMenu(title: Self.fingerprintLabel(model.config?.tlsFingerprint ?? ""), options: [""] + Config.tlsFingerprints,
                           label: Self.fingerprintLabel, selected: model.config?.tlsFingerprint ?? "") { v in Task { await model.setTLSFingerprint(v) } }
                    .disabled(model.busy)
            }
        }
    }

    // MARK: Test

    private var method: TestMethod { TestMethod(rawValue: testMethod) ?? .connect }

    @ViewBuilder private var testSection: some View {
        SettingsSection("Test") {
            FormRow("Test method", detail: method.detail) {
                SelectMenu(title: method.title, options: TestMethod.allCases, label: { $0.title }, selected: method) { testMethod = $0.rawValue }
            }
            Hairline()
            FormRow("Timeout", detail: "Give up after this long.") {
                SelectMenu(title: "\(testTimeout) s", options: [1, 2, 3, 5, 10, 15, 30], label: { "\($0) s" }, selected: testTimeout) { testTimeout = $0 }
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
        }
    }

    private static let customChoice = "Custom"
    private static let urlChoices = Prefs.testURLPresets.map(\.name) + [customChoice]
    /// The preset the saved address belongs to, or Custom.
    private var urlChoice: String { Prefs.testURLPresets.first { $0.url == testURL }?.name ?? Self.customChoice }

}

/// How a server is measured. TCP and ICMP time the server's own address, outside the tunnel; CONNECT times a request
/// through it.
enum TestMethod: String, CaseIterable {
    case tcp, icmp, connect

    var title: String { self == .connect ? "CONNECT" : rawValue.uppercased() }

    var detail: String {
        switch self {
        case .tcp: "Time to connect to the server's port. Not for UDP servers (WireGuard, Hysteria2, TUIC)."
        case .icmp: "Server ping time. Not available while the kill switch is on."
        case .connect: "A request through the server."
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
                Text("An https address with a small reply.")
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
