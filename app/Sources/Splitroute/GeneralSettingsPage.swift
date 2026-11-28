import Design
import SwiftUI

/// A switch with no label of its own (the row carries the text).
func settingsSwitch(_ title: String, isOn: Binding<Bool>) -> some View {
    Toggle(title, isOn: isOn).labelsHidden().toggleStyle(.switch).tint(Accent.color)
}

/// Settings > General: what most people use: the kill switch, connecting, server switching, and when subscriptions and
/// routing lists update. The most important setting of a group comes first.
struct GeneralSettingsPage: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage(Prefs.alwaysOn) private var alwaysOn = false
    @AppStorage(Prefs.disconnectOnSleep) private var disconnectOnSleep = false
    @AppStorage(Prefs.showDisconnectMessage) private var showMessage = false
    @AppStorage(Prefs.sortByPing) private var sortByPing = true
    @AppStorage(Prefs.autoSwitch) private var autoSwitch = false
    @AppStorage(Prefs.subsUpdateOnOpen) private var subsOnOpen = false
    @AppStorage(Prefs.subsAutoUpdate) private var subsAuto = true
    @AppStorage(Prefs.subsIntervalHours) private var subsHours = 24
    @AppStorage(Prefs.listsAutoUpdate) private var listsAuto = true
    @AppStorage(Prefs.listsUpdateOnOpen) private var listsOnOpen = false
    @AppStorage(Prefs.listsIntervalHours) private var listsHours = 24
    @AppStorage(Prefs.subsLastAttempt) private var subsLast = 0.0
    @AppStorage(Prefs.listsLastAttempt) private var listsLast = 0.0


    var body: some View {
        SettingsPage("General") {
            if model.status == nil { ServiceUnavailable() }
            if model.status != nil { killSwitch; alwaysOnSection; failoverSection }
            subscriptions
            routingLists
        }
    }

    private func toggle(_ title: String, isOn: Binding<Bool>) -> some View { settingsSwitch(title, isOn: isOn) }

    // MARK: Kill switch

    @ViewBuilder private var killSwitch: some View {
        SettingsSection("Kill switch") {
            FormRow("Block traffic if the connection drops",
                    detail: "Blocks the network if the server drops, instead of using your normal connection.",
                    error: model.error("killswitch")) {
                toggle("Block traffic if the connection drops", isOn: Binding(get: { model.killSwitchOn }, set: { on in Task { await model.setKillSwitch(on: on) } }))
                    .disabled(model.busy)
            }
            Hairline()
            FormRow("Allow the local network", detail: "Keep printers and your router reachable.") {
                toggle("Allow the local network", isOn: Binding(get: { model.killSwitchLAN }, set: { on in Task { await model.setKillSwitch(lan: on) } }))
                    .disabled(model.busy || !model.killSwitchOn)
            }
            Hairline()
            NoteLine(.warning, "Stays on after a restart until you connect. Programs running as root can bypass it.")
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Space.l)
        }
    }

    // MARK: Always on

    @ViewBuilder private var alwaysOnSection: some View {
        SettingsSection("Connection") {
            FormRow("Always on",
                    detail: "Connect when the app opens or the Mac wakes. A server that failed is not retried.") {
                settingsSwitch("Always on", isOn: Binding(get: { alwaysOn }, set: { on in alwaysOn = on; Task { await model.setAlwaysOn(on) } }))
            }
            Hairline()
            FormRow("Disconnect on sleep",
                    detail: model.killSwitchOn
                        ? "Unavailable while the kill switch is on."
                        : "Disconnect when the Mac sleeps.") {
                settingsSwitch("Disconnect on sleep", isOn: $disconnectOnSleep).disabled(model.killSwitchOn)
            }
            Hairline()
            FormRow("Show disconnect message", detail: "Notify when it disconnects for sleep.") {
                settingsSwitch("Show disconnect message", isOn: Binding(get: { showMessage }, set: { showMessage = $0; model.setShowDisconnectMessage($0) }))
                    .disabled(!disconnectOnSleep || model.killSwitchOn)
            }
        }
    }

    // MARK: Failover

    @ViewBuilder private var failoverSection: some View {
        SettingsSection("Servers") {
            FormRow("Switch servers automatically",
                    detail: "Use the quickest other server if the active one stops answering. A list that names a server stays blocked while it is down.") {
                settingsSwitch("Switch servers automatically", isOn: Binding(get: { autoSwitch }, set: { autoSwitch = $0; model.setAutoSwitch($0) }))
            }
            Hairline()
            FormRow("Sort by ping", detail: "Fastest first after a test.") {
                settingsSwitch("Sort by ping", isOn: $sortByPing)
            }
            if let note = model.lastFailover {
                Hairline()
                Text(note).font(TypeScale.secondary).foregroundStyle(Palette.inkSecondary.color)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(Space.l)
            }
        }
    }

    private static func hours(_ h: Int) -> String { h == 1 ? "1 hour" : h < 48 ? "\(h) hours" : "\(h / 24) days" }

    @ViewBuilder private var subscriptions: some View {
        SettingsSection("Subscription updates") {
            FormRow("Auto update",
                    detail: "Update while the app runs. Nothing updates after you quit.") {
                settingsSwitch("Auto update", isOn: $subsAuto)
            }
            Hairline()
            FormRow("Interval") {
                SelectMenu(title: Self.hours(subsHours), options: Prefs.subsIntervals, label: Self.hours, selected: subsHours) { subsHours = $0 }
            }
            .disabled(!subsAuto)
            Hairline()
            FormRow("Update on open", detail: "Update all when the app opens.") {
                settingsSwitch("Update on open", isOn: $subsOnOpen)
            }
            Hairline()
            ValueRow("Last update attempt", Self.time(subsLast))
            Hairline()
            ValueRow("Next update attempt", subsAuto ? Self.next(subsLast, hours: subsHours) : "Off")
        }
    }

    @ViewBuilder private var routingLists: some View {
        SettingsSection("Routing list updates") {
            FormRow("Auto update", detail: "Refresh ready-made lists on a schedule. Imported lists use their own.") {
                settingsSwitch("Auto update", isOn: $listsAuto)
            }
            Hairline()
            FormRow("Interval") {
                SelectMenu(title: Self.hours(listsHours), options: Prefs.listsIntervals, label: Self.hours, selected: listsHours) { listsHours = $0 }
            }
            .disabled(!listsAuto)
            Hairline()
            FormRow("Update on open", detail: "Download again when the app opens.") {
                settingsSwitch("Update on open", isOn: $listsOnOpen)
            }
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
