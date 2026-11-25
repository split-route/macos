import Design
import SwiftUI

/// "Where would this go?": type a name or an address and see which list decides and what it does, by the lists the service has
/// now. Matched by name only (a name isn't resolved), as a TCP connection; the service says so in a note.
struct RouteTester: View {
    @EnvironmentObject private var model: AppModel
    @State private var query = ""
    @State private var result: WireRoute?
    @State private var error: String?
    @State private var working = false
    @FocusState private var focused: Bool

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: Space.m) {
                HStack(spacing: Space.s) {
                    Image(systemName: "scope").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.inkSecondary.color).accessibilityHidden(true)
                    TextField("Test a domain or address", text: $query, prompt: Text("example.com or 203.0.113.5").foregroundColor(.secondary))
                        .labelsHidden().textFieldStyle(.plain).multilineTextAlignment(.leading).focused($focused)
                        .onSubmit { run() }
                        .onChange(of: query) { _, _ in result = nil; error = nil }
                    if working { ProgressView().controlSize(.small) }
                    Button("Test") { run() }.buttonStyle(OutlineButtonStyle())
                        .disabled(working || query.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let error { NoteLine(.error, error) }
                if let r = result { answer(r) }
            }
            .padding(Space.l)
        }
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
        if let notes = r.notes, !notes.isEmpty {
            Text(notes.joined(separator: " ")).font(TypeScale.secondary).foregroundStyle(Palette.inkSecondary.color.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
        }
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
        case "list": return "Matched by the list “\(r.list ?? "")”."
        case "local": return "A local network address always stays direct."
        case "ipv6": return "IPv6 is blocked (Settings > Network). Turn that off to send it where the default route says."
        default: return "No list matches, so the default route decides."
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
