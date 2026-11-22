import SwiftUI

struct GeneralPage: View {
    @EnvironmentObject private var model: AppModel
    @State private var presetID = ""
    @State private var confirmPreset = false
    @AppStorage("quitAction") private var quitAction = "" // read by AppDelegate.quit

    var body: some View {
        Form {
            if model.status == nil {
                ServiceUnavailable()
            } else {
                routingSection
                if model.ready { presetSection }
            }
            appSection
        }
    }

    private var routingSection: some View {
        Section {
            SettingRow("Apply lists", description: model.summary + "\n" + (model.status?.enabled == false ? "Off: connected tunnels carry all traffic." : "On: each list goes direct, is blocked, or goes through its tunnel."),
                       error: model.actionError) {
                Toggle("Apply lists", isOn: Binding(
                    get: { model.status?.enabled ?? false },
                    set: { on in Task { await model.setEnabled(on) } }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(model.busy)
            }
            if model.serviceOutdated, let v = model.status?.version {
                SettingRow("Service update", description: "The service is version \(v); this app is \(AppModel.appVersion).") {
                    Button("Update Service") { Task { await model.restartService() } }
                        .disabled(model.busy)
                }
            }
            ForEach(model.status?.warnings ?? [], id: \.self) { WarningText($0) }
        }
    }

    private var presetSection: some View {
        Section {
            SettingRow("Preset", description: presetDescription, error: model.error("preset")) {
                SelectMenu(title: model.presets.first { $0.id == presetID }?.name ?? "Choose…",
                           options: model.presets.map(\.id),
                           label: { id in model.presets.first { $0.id == id }?.name ?? id },
                           selected: presetID) { presetID = $0 }
                Button("Apply…") { confirmPreset = true }
                    .disabled(presetID.isEmpty || model.busy)
            }
        } header: {
            Text("Preset")
        }
        .confirmationDialog("Apply this preset?", isPresented: $confirmPreset) {
            Button("Apply") { Task { await model.applyPreset(presetID) } }
        } message: {
            Text("The current release lists are replaced. Your own lists and imports are kept.")
        }
    }

    private var presetDescription: String {
        guard let p = model.presets.first(where: { $0.id == presetID }) else {
            return "Replaces the release lists with a ready-made set. Your own lists and imports are kept."
        }
        return p.lists.map { "\($0.action.label): \($0.name)" }.joined(separator: " · ")
    }

    private static let quitLabels = ["": "Ask", "turnOff": "Disconnect tunnels", "keep": "Keep connected"]

    private var appSection: some View {
        Section {
            SettingRow("Open at login", description: "Show the connection state in the menu bar after you log in.") {
                Toggle("Open at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            SettingRow("When quitting while connected", description: "The service runs on its own: with Keep connected, quitting only closes the menu bar icon.") {
                SelectMenu(title: Self.quitLabels[quitAction] ?? "Ask", options: ["", "turnOff", "keep"],
                           label: { Self.quitLabels[$0] ?? $0 }, selected: quitAction) { quitAction = $0 }
            }
        } header: {
            Text("App")
        }
    }
}
