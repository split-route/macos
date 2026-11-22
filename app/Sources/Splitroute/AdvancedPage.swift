import AppKit
import SwiftUI

struct AdvancedPage: View {
    @EnvironmentObject private var model: AppModel
    @State private var baseURL = ""
    @State private var confirmUninstall = false

    static let defaultBaseURL = "https://github.com/aliraghebi/routing-rules/releases/latest/download" // config.DefaultBaseURL
    static let logPath = "/var/log/splitroute.log"
    static let databasePath = "/var/db/splitroute/splitroute.db"

    private var saved: String { model.config?.baseURL ?? "" }

    var body: some View {
        Form {
            if model.ready {
                Section {
                    SettingRow("Release URL", description: "Where release lists and their SHA256SUMS are downloaded from (https only). Empty: the routing-rules releases.",
                               error: model.error("baseURL"))
                    TextField("Release URL", text: $baseURL, prompt: Text(Self.defaultBaseURL))
                        .labelsHidden()
                        .fontDesign(.monospaced)
                        .onSubmit(save)
                    HStack {
                        Spacer()
                        Button("Use Default") {
                            baseURL = ""
                            save()
                        }
                        .disabled(saved.isEmpty || model.busy)
                        Button("Save", action: save)
                            .disabled(baseURL.trimmingCharacters(in: .whitespaces) == saved || model.busy)
                    }
                } header: {
                    Text("List source")
                }
            }
            Section {
                SettingRow("Log file", description: Self.logPath) {
                    Button("Show in Finder") { reveal(Self.logPath) }
                }
                SettingRow("Settings database", description: "\(Self.databasePath)\nExport or import it as JSON with splitroute config export / import.") {
                    Button("Show in Finder") { reveal(Self.databasePath) }
                }
            } header: {
                Text("Files")
            }
            Section {
                SettingRow("Restart service", description: "Restarts the service from this app's copy of splitroute. Routes stay in place. Turn it off or on in System Settings > General > Login Items.",
                           error: model.actionError) {
                    Button("Restart") { Task { await model.restartService() } }
                        .disabled(model.busy)
                }
                SettingRow("Uninstall service", description: "Stops the service and removes its routes. Your settings are kept.") {
                    Button("Uninstall…", role: .destructive) { confirmUninstall = true }
                        .disabled(model.busy || model.connError == .notRunning)
                }
            } header: {
                Text("System service")
            }
        }
        .onAppear { baseURL = saved }
        .onChange(of: saved) { baseURL = $0 }
        .confirmationDialog("Uninstall the Splitroute service?", isPresented: $confirmUninstall) {
            Button("Uninstall", role: .destructive) { Task { await model.uninstallService() } }
        } message: {
            Text("Routing stops and its routes are removed until you install the service again.")
        }
    }

    private func save() {
        let u = baseURL.trimmingCharacters(in: .whitespaces)
        guard u != saved else { return }
        Task { await model.setBaseURL(u.isEmpty ? nil : u) }
    }

    private func reveal(_ path: String) {
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }
}
