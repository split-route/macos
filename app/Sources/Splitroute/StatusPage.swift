import Design
import SwiftUI

/// What the service sees: tunnels, applied lists, problems and imports.
struct StatusPage: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        PageScaffold("Status", summary: model.status == nil ? "The service isn't running." : model.summary) {
            EmptyView()
        } content: {
            if let s = model.status {
                SectionTitle("Connection")
                Panel {
                    ValueRow("VPN", model.vpnOn ? "On" : "Off", detail: model.vpnOn ? nil : "Traffic uses your normal connection.")
                    Hairline()
                    ValueRow("Tunnel", model.selectedTunnel?.name ?? "None selected", detail: model.vpnOn ? model.summary : nil)
                    Hairline()
                    ValueRow("Kill switch", model.killSwitchOn ? (model.killSwitchArmed ? "Blocking leaks" : "Not active") : "Off",
                             detail: model.killSwitchOn && !model.killSwitchArmed ? (model.vpnOn ? "The service hasn't loaded the rules; see Problems." : "Active while the VPN is on.") : nil)
                    Hairline()
                    ValueRow("Routing", s.enabled ? "Applied" : "Off", detail: s.enabled ? nil : "Connected tunnels carry all traffic.")
                    Hairline()
                    ValueRow("Release lists downloaded", parseGoTime(s.fetched).map(relative) ?? "Never")
                    Hairline()
                    ValueRow("Service version", s.version)
                }
                if s.error != nil || !(s.warnings ?? []).isEmpty {
                    SectionTitle("Problems")
                    Panel {
                        VStack(alignment: .leading, spacing: Space.s) {
                            if let e = s.error { NoteLine(.error, e) }
                            ForEach(s.warnings ?? [], id: \.self) { NoteLine(.warning, $0) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Space.l)
                    }
                }
                SectionTitle("Entries per list")
                Panel {
                    if s.lists.isEmpty {
                        Text("No lists are applied.").font(TypeScale.body).foregroundStyle(Palette.inkSecondary.color)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(Space.l)
                    }
                    ForEach(Array(s.lists.enumerated()), id: \.element.name) { i, l in
                        if i > 0 { Hairline() }
                        ValueRow(model.info(l.name)?.title ?? l.name, plural(l.entries, "entry", "entries"), detail: l.action.label)
                    }
                }
                if let imports = s.imports, !imports.isEmpty {
                    SectionTitle("Imports")
                    Panel {
                        ForEach(Array(imports.enumerated()), id: \.element.name) { i, im in
                            if i > 0 { Hairline() }
                            ValueRow(im.name, parseGoTime(im.fetchedAt).map(relative) ?? "Not downloaded", detail: importDetail(im))
                        }
                    }
                }
            } else {
                ServiceUnavailable()
            }
        }
    }

    private func importDetail(_ im: ImportStatus) -> String {
        var parts = ["\(plural(im.entries, "entry", "entries"))"]
        if let n = im.skipped, n > 0 { parts.append("\(plural(n, "line")) skipped") }
        if let c = parseGoTime(im.checkedAt) { parts.append("checked \(relative(c))") }
        if let e = im.error { parts.append("last download failed: \(e)") }
        return parts.joined(separator: ", ")
    }
}
