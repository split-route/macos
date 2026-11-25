import Design
import SwiftUI

/// Settings > Updates: when subscriptions and the ready-made routing lists download again.
struct UpdatesSettingsPage: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage(Prefs.subsUpdateOnOpen) private var subsOnOpen = false
    @AppStorage(Prefs.subsAutoUpdate) private var subsAuto = true
    @AppStorage(Prefs.subsIntervalHours) private var subsHours = 24
    @AppStorage(Prefs.listsAutoUpdate) private var listsAuto = true
    @AppStorage(Prefs.listsUpdateOnOpen) private var listsOnOpen = false
    @AppStorage(Prefs.listsIntervalHours) private var listsHours = 24
    @AppStorage(Prefs.subsLastAttempt) private var subsLast = 0.0
    @AppStorage(Prefs.listsLastAttempt) private var listsLast = 0.0

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
            Hairline()
            ValueRow("Last update attempt", Self.time(subsLast))
            Hairline()
            ValueRow("Next update attempt", subsAuto ? Self.next(subsLast, hours: subsHours) : "Off")
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
            Hairline()
            ValueRow("Last update attempt", Self.time(listsLast))
            Hairline()
            ValueRow("Next update attempt", listsAuto ? Self.next(listsLast, hours: listsHours) : "Off")
        }
    }

    private static func time(_ t: Double) -> String {
        t > 0 ? Date(timeIntervalSince1970: t).formatted(date: .abbreviated, time: .shortened) : "Never"
    }

    /// The last attempt plus the interval, or "Soon" when there was none or that time has passed.
    private static func next(_ last: Double, hours: Int) -> String {
        let t = last + Double(hours) * 3600
        return last > 0 && t > Date().timeIntervalSince1970 ? time(t) : "Soon"
    }
}
