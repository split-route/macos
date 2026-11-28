import Design
import SwiftUI

/// "Where would this go?": type a name or an address and see which list decides and what it does, by the lists the service has
/// now. Matched by name only (a name isn't resolved), as a TCP connection; the service says so in a note. A dialog opened
/// from the Routing page's top bar.
struct RouteTestSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var result: WireRoute?
    @State private var error: String?
    @State private var working = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Space.m) {
                Text("Test a route").font(TypeScale.bodyStrong)
                TextField("Test a domain or address", text: $query, prompt: Text("example.com or 203.0.113.5").foregroundColor(.secondary))
                    .labelsHidden().textFieldStyle(.plain).multilineTextAlignment(.leading).fieldBox().focused($focused)
                    .onSubmit { run() }
                    .onChange(of: query) { _, _ in result = nil; error = nil }
                if let r = result { answer(r) }
            }
            .padding(Space.xl)
            SheetButtons(error: error) {
                if working { ProgressView().controlSize(.small) }
                Button("Close", role: .cancel) { dismiss() }.buttonStyle(OutlineButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Test") { run() }.buttonStyle(SolidButtonStyle()).keyboardShortcut(.defaultAction)
                    .disabled(working || query.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .frame(width: 480)
        .onAppear { focused = true }
    }

    @ViewBuilder private func answer(_ r: WireRoute) -> some View {
        let (title, color) = outcome(r)
        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            Circle().fill(color).frame(width: 8, height: 8).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(TypeScale.bodyStrong).foregroundStyle(Palette.ink.color)
                Text(why(r)).font(TypeScale.secondary).foregroundStyle(Palette.inkSecondary.color).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func outcome(_ r: WireRoute) -> (String, Color) {
        switch r.action {
        case .block, .none: return ("Blocked", Palette.danger.color)
        case .direct: return ("Direct", Palette.success.color)
        case .tunnel: return (r.tunnel.map { "Through \($0)" } ?? "Through the active server", Accent.color)
        }
    }

    private func why(_ r: WireRoute) -> String {
        switch r.kind {
        case "list": return "Matched by the rule “\(r.list ?? "")”."
        case "local": return "A local network address always stays direct."
        case "ipv6": return "IPv6 is blocked (Settings > Advanced). Turn that off to send it where the default route says."
        default: return "No rule matches, so the default route decides."
        }
    }

    private func run() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, !working else { return }
        working = true
        error = nil
        Task {
            do { result = try await Daemon.routeTest(q) } catch { result = nil; self.error = error.localizedDescription }
            working = false
        }
    }
}
