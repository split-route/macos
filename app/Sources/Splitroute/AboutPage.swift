import AppKit
import SwiftUI

struct AboutPage: View {
    @EnvironmentObject private var model: AppModel

    private static let repo = URL(string: "https://github.com/split-route/macos")!
    private static let releases = URL(string: "https://github.com/split-route/macos/releases")!
    private static let rules = URL(string: "https://github.com/aliraghebi/routing-rules")!

    var body: some View {
        Form {
            Section {
                VStack(spacing: 8) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 96, height: 96)
                    Text("Splitroute").font(.title2.weight(.semibold)).fontDesign(.rounded)
                    Text("Version \(AppModel.appVersion)").foregroundStyle(.secondary)
                    if let v = model.status?.version, v != AppModel.appVersion {
                        Text("Service version \(v)").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            Section {
                SettingRow("Updates", description: "With Homebrew: brew upgrade --cask splitroute. Otherwise download the DMG from the releases page.") {
                    Link("Releases", destination: Self.releases)
                }
                SettingRow("Source code", description: "github.com/split-route/macos") {
                    Link("Open", destination: Self.repo)
                }
                SettingRow("Lists", description: "github.com/aliraghebi/routing-rules") {
                    Link("Open", destination: Self.rules)
                }
                ValueRow("License", "GPL-3.0")
            }
        }
    }
}
