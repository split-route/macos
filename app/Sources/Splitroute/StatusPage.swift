import SwiftUI

struct StatusPage: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            if let s = model.status {
                Section {
                    ValueRow("Tunnels", s.connected == 0 ? "None connected" : "\(s.connected) connected", description: model.summary)
                    ValueRow("Lists", s.enabled ? "Applied" : "Off", description: s.enabled ? nil : "Connected tunnels carry all traffic.")
                    ValueRow("Release lists downloaded", parseGoTime(s.fetched).map(relative) ?? "Never")
                    ValueRow("Service version", s.version)
                } header: {
                    Text("Connection")
                }
                if s.error != nil || !(s.warnings ?? []).isEmpty {
                    Section {
                        if let e = s.error { ErrorText(e) }
                        ForEach(s.warnings ?? [], id: \.self) { WarningText($0) }
                    } header: {
                        Text("Problems")
                    }
                }
                Section {
                    if s.lists.isEmpty { Text("No lists are applied.").foregroundStyle(.secondary) }
                    ForEach(s.lists, id: \.name) { l in
                        ValueRow(l.name, plural(l.entries, "entry", "entries"), description: l.action.label)
                    }
                } header: {
                    Text("Entries per list")
                }
                if let imports = s.imports, !imports.isEmpty {
                    Section {
                        ForEach(imports, id: \.name) { im in
                            ValueRow(im.name, parseGoTime(im.fetchedAt).map(relative) ?? "Not downloaded",
                                     description: importDetail(im))
                        }
                    } header: {
                        Text("Imports")
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
        return parts.joined(separator: " · ")
    }
}
