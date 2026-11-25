import Design
import SwiftUI

/// Settings > Updates: when subscriptions and the ready-made routing lists download again.
struct UpdatesSettingsPage: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage(Prefs.subsUpdateOnOpen) private var subsOnOpen = false
    @AppStorage(Prefs.subsAutoUpdate) private var subsAuto = false
    @AppStorage(Prefs.subsIntervalHours) private var subsHours = 12
    @AppStorage(Prefs.listsAutoUpdate) private var listsAuto = true
    @AppStorage(Prefs.listsUpdateOnOpen) private var listsOnOpen = false
    @AppStorage(Prefs.listsIntervalHours) private var listsHours = 24

    var body: some View {
        PageScaffold("Updates") {
            EmptyView()
        } content: {
            subscriptions
            routingLists
        }
    }

    // MARK: Updates

    private static func hours(_ h: Int) -> String { h == 1 ? "1 hour" : h < 48 ? "\(h) hours" : "\(h / 24) days" }

    @ViewBuilder private var subscriptions: some View {
        SectionTitle("Subscriptions")
        Panel {
            FormRow("Update on open", detail: "Update every subscription when Splitroute opens.") {
                settingsSwitch("Update on open", isOn: $subsOnOpen)
            }
            Hairline()
            FormRow("Auto update",
                    detail: "Update in the background while Splitroute runs. After quitting the app or restarting the Mac, nothing updates until it opens again.") {
                settingsSwitch("Auto update", isOn: $subsAuto)
            }
            Hairline()
            FormRow("Interval") {
                SelectMenu(title: Self.hours(subsHours), options: Prefs.subsIntervals, label: Self.hours, selected: subsHours) { subsHours = $0 }
            }
            .disabled(!subsAuto)
        }
    }

    @ViewBuilder private var routingLists: some View {
        SectionTitle("Routing lists")
        Panel {
            FormRow("Update on open", detail: "Download every list again when Splitroute opens.") {
                settingsSwitch("Update on open", isOn: $listsOnOpen)
            }
            Hairline()
            FormRow("Auto update", detail: "Download the ready-made lists again on this schedule. A list imported from an address uses its own refresh time. With this off, only lists you ask for download.") {
                settingsSwitch("Auto update", isOn: $listsAuto)
            }
            Hairline()
            FormRow("Interval") {
                SelectMenu(title: Self.hours(listsHours), options: Prefs.listsIntervals, label: Self.hours, selected: listsHours) { listsHours = $0 }
            }
            .disabled(!listsAuto)
        }
    }
}
