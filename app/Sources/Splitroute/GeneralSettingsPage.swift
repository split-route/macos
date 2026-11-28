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
    @AppStorage(Prefs.smartInterval) private var smartInterval = 3600
    @AppStorage(Prefs.smartHealth) private var smartHealth = 30
    @AppStorage(Prefs.smartTolerance) private var smartTolerance = 50
    @AppStorage(Prefs.smartGroupOnly) private var smartGroupOnly = true
    @AppStorage(Prefs.smartPool) private var smartPool = 48
    @AppStorage(Prefs.smartOnNetwork) private var smartOnNetwork = true
    @AppStorage(Prefs.smartAfterTest) private var smartAfterTest = true
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
            if model.status != nil { killSwitch; alwaysOnSection; smartSelectSection; serversSection }
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

    // MARK: Smart Select

    private static func every(_ s: Int) -> String { s == 0 ? "Never" : s < 3600 ? "\(s / 60) min" : "\(s / 3600) h" }
    private static func seconds(_ s: Int) -> String { s == 0 ? "Off" : s < 60 ? "\(s) s" : "\(s / 60) min" }

    @ViewBuilder private var smartSelectSection: some View {
        SettingsSection("Smart Select") {
            FormRow("Check servers every", detail: "Compare the servers and use the best. Also runs when you turn it on.") {
                SelectMenu(title: Self.every(smartInterval), options: Prefs.smartIntervals, label: Self.every, selected: smartInterval) { smartInterval = $0 }
            }
            Hairline()
            FormRow("Check the active server", detail: "One request through it. Three misses in a row switch to the best server.") {
                SelectMenu(title: Self.seconds(smartHealth), options: Prefs.smartHealths, label: Self.seconds, selected: smartHealth) { smartHealth = $0 }
            }
            Hairline()
            FormRow("Switch only if faster by", detail: "Keeps similar servers from taking turns.") {
                SelectMenu(title: "\(smartTolerance) ms", options: Prefs.smartTolerances, label: { "\($0) ms" }, selected: smartTolerance) { smartTolerance = $0 }
            }
            Hairline()
            FormRow("Choose from", detail: "A group is a subscription. Servers you added by hand are one group.") {
                SelectMenu(title: smartGroupOnly ? "Active server's group" : "All servers", options: [true, false],
                           label: { $0 ? "Active server's group" : "All servers" }, selected: smartGroupOnly) { smartGroupOnly = $0 }
            }
            Hairline()
            FormRow("Servers per check", detail: "More takes longer and uses more data.") {
                SelectMenu(title: "\(smartPool)", options: Prefs.smartPools, label: { "\($0)" }, selected: smartPool) { smartPool = $0 }
            }
            Hairline()
            FormRow("Check when the network changes", detail: "Another Wi-Fi or cable can change which server is best.") {
                settingsSwitch("Check when the network changes", isOn: $smartOnNetwork)
            }
            Hairline()
            FormRow("Switch after a manual test", detail: "After Test, move to the fastest server.") {
                settingsSwitch("Switch after a manual test", isOn: $smartAfterTest)
            }
            Hairline()
            Text("Uses the test address and timeout from Advanced. OpenVPN servers are never chosen or left. A list that names a server stays blocked while that server is down.")
                .font(TypeScale.secondary).foregroundStyle(Palette.inkSecondary.color).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading).padding(Space.l)
        }
    }

    @ViewBuilder private var serversSection: some View {
        SettingsSection("Servers") {
            FormRow("Sort by ping", detail: "Fastest first after a test.") {
                settingsSwitch("Sort by ping", isOn: $sortByPing)
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
