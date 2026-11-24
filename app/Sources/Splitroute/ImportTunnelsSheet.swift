import AppKit
import Design
import SwiftUI

/// Adds tunnels from share links, a subscription address, or a subscription's
/// contents. An address is a subscription: the service downloads it, keeps the
/// address (on this Mac, readable only by the service) and groups its tunnels.
/// Nothing is read from the clipboard until the user asks.
struct ImportTunnelsSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    /// Closes this sheet and opens the OpenVPN profile one.
    let openProfile: () -> Void

    @State private var text: String
    @State private var group = ""
    @State private var working = false
    @State private var error: String?
    @State private var result: AddResult?
    @FocusState private var editing: Bool

    /// The initial text and result are for the debug snapshots; the app opens the sheet empty.
    init(openProfile: @escaping () -> Void, text: String = "", result: AddResult? = nil) {
        self.openProfile = openProfile
        self._text = State(initialValue: text)
        self._result = State(initialValue: result)
    }

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// One word that starts with http:// or https://.
    private var isAddress: Bool {
        !trimmed.contains(where: \.isWhitespace) && (trimmed.hasPrefix("https://") || trimmed.hasPrefix("http://"))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            if let result { resultView(result) } else if working { workingView } else { inputView }
        }
        .padding(Space.xl)
        .frame(width: 540)
        .background(Palette.surface.color)
        .font(TypeScale.body)
        .foregroundStyle(Palette.ink.color)
    }

    // MARK: Input

    private var inputView: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Add servers").font(TypeScale.title)
                Text("Paste share links (vless://, vmess://, trojan://, ss://, hysteria2://, tuic://, anytls://), a subscription address, or the contents of a subscription.")
                    .font(TypeScale.secondary).foregroundStyle(Palette.inkSecondary.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ZStack(alignment: .topLeading) {
                TextEditor(text: $text)
                    .font(.system(size: 12, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .focused($editing)
                    .padding(Space.s)
                    .accessibilityLabel("Links or subscription address")
                if text.isEmpty {
                    Text("vless://…\nhttps://example.com/subscription")
                        .font(.system(size: 12, design: .monospaced)).foregroundStyle(Palette.inkSecondary.color)
                        .padding(.horizontal, Space.s + 5).padding(.vertical, Space.s + 8).allowsHitTesting(false)
                }
            }
            .frame(height: 140)
            .background(Palette.ground.color, in: RoundedRectangle(cornerRadius: Radius.control))
            .overlay(RoundedRectangle(cornerRadius: Radius.control)
                .stroke(editing ? Palette.ink.color : Palette.hairline.color, lineWidth: editing ? 2 : 1))

            HStack {
                Button("Paste from clipboard") {
                    if let s = NSPasteboard.general.string(forType: .string) { text = s }
                }
                .buttonStyle(OutlineButtonStyle())
                Spacer()
            }

            if isAddress { addressNote }
            if let error { NoteLine(.error, error) }

            HStack {
                Button("Import an OpenVPN profile instead", action: openProfile)
                    .buttonStyle(.plain).font(TypeScale.secondary).foregroundStyle(Palette.inkSecondary.color)
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(OutlineButtonStyle()).keyboardShortcut(.cancelAction)
                Button(isAddress ? "Download and add" : "Add") { Task { await add() } }
                    .buttonStyle(SolidButtonStyle()).keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty || (isAddress && trimmed.hasPrefix("http://")))
            }
        }
        .onAppear { editing = true }
    }

    /// What an address means: it becomes a group, and the address is private.
    private var addressNote: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            if trimmed.hasPrefix("http://") {
                NoteLine(.error, "Subscriptions must use https://, because the address carries your token.")
            } else {
                Text("This is a subscription. Its servers are kept in their own group, and the address stays on this Mac where only the service can read it.")
                    .font(TypeScale.secondary).foregroundStyle(Palette.inkSecondary.color)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Space.s) {
                    Text("Group name").font(TypeScale.secondary).foregroundStyle(Palette.inkSecondary.color)
                    TextField(URL(string: trimmed)?.host ?? "Subscription", text: $group)
                        .textFieldStyle(.roundedBorder).labelsHidden()
                        .accessibilityLabel("Group name")
                }
            }
        }
    }

    private var workingView: some View {
        HStack(spacing: Space.m) {
            ProgressView().controlSize(.small)
            Text(isAddress ? "Downloading the subscription…" : "Adding servers…").font(TypeScale.body)
        }
        .frame(maxWidth: .infinity, minHeight: 120)
    }

    // MARK: Result

    @ViewBuilder private func resultView(_ r: AddResult) -> some View {
        let skipped = r.skipped ?? []
        VStack(alignment: .leading, spacing: 4) {
            Text(r.added == 0 ? "Nothing was added" : "Added \(plural(r.added, "server"))").font(TypeScale.title)
            Text(summary(r, skipped: skipped.count)).font(TypeScale.secondary)
                .foregroundStyle(Palette.inkSecondary.color).fixedSize(horizontal: false, vertical: true)
        }
        if !skipped.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.s) {
                    ForEach(skipped) { s in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(s.label).font(TypeScale.bodyStrong).lineLimit(1)
                            Text(s.reason).font(TypeScale.secondary).foregroundStyle(Palette.inkSecondary.color)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(Space.m)
            }
            .frame(maxHeight: 180)
            .background(Palette.ground.color, in: RoundedRectangle(cornerRadius: Radius.control))
        }
        HStack {
            Spacer()
            if r.added == 0 { Button("Back") { result = nil }.buttonStyle(OutlineButtonStyle()) }
            Button("Done") { dismiss() }.buttonStyle(SolidButtonStyle()).keyboardShortcut(.defaultAction)
        }
    }

    private func summary(_ r: AddResult, skipped: Int) -> String {
        var parts: [String] = []
        if let g = r.group { parts.append("They are in the group “\(g)”.") }
        if skipped > 0 {
            parts.append(r.added == 0
                ? "\(plural(skipped, "link")) couldn't be used:"
                : "\(plural(skipped, "link")) were skipped:")
        } else if r.added > 0 {
            parts.append("Connect one from the list.")
        }
        return parts.joined(separator: " ")
    }

    // MARK: Action

    private func add() async {
        error = nil
        working = true
        let name = group.trimmingCharacters(in: .whitespaces)
        let r = await model.addTunnels(text: isAddress ? nil : text, url: isAddress ? trimmed : nil, name: name)
        working = false
        switch r {
        case .success(let res): result = res
        case .failure(let e): error = e.localizedDescription
        }
    }
}
