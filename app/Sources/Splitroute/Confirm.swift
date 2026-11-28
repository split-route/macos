import AppKit

/// Asks before something the person did that is easy to do by accident (disconnecting, changing the routing profile). The
/// question has "Don't ask again", which turns its setting off (Settings > Application > Confirmations, on by default).
@MainActor enum Confirm {
    /// True to go on. With the setting off nothing is asked. Cancel asks the same next time; confirming with the box ticked turns
    /// the setting off.
    static func ask(_ key: String, title: String, detail: String, confirm: String) -> Bool {
        guard Prefs.bool(key, true) else { return true }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        if alert.suppressionButton?.state == .on { UserDefaults.standard.set(false, forKey: key) }
        return true
    }
}

extension AppModel {
    /// Before the connection is turned off from a switch. A cancel redraws the switch (it moved when it was clicked).
    func confirmDisconnect() -> Bool {
        let blocked = killSwitchOn ? " The kill switch is on, so the network stays blocked until you connect again." : " Traffic goes direct until you connect again."
        let ok = Confirm.ask(Prefs.confirmDisconnect, title: "Disconnect?", detail: "The connection will be turned off." + blocked, confirm: "Disconnect")
        if !ok { objectWillChange.send() }
        return ok
    }

    /// Before routing is turned off from a switch. A cancel redraws the switch.
    func confirmRoutingOff() -> Bool {
        let ok = Confirm.ask(Prefs.confirmRouting, title: "Turn off routing?",
                             detail: "The rules stop applying. Only the default route is used.", confirm: "Turn Off")
        if !ok { objectWillChange.send() }
        return ok
    }

    /// Before the kill switch is turned off from a switch. A cancel redraws the switch.
    func confirmKillSwitchOff() -> Bool {
        let ok = Confirm.ask(Prefs.confirmKillSwitch, title: "Turn off the kill switch?",
                             detail: "If the connection drops, traffic will use your normal network instead of being blocked.", confirm: "Turn Off")
        if !ok { objectWillChange.send() }
        return ok
    }

    /// Before another routing profile is made the active one.
    func confirmProfileChange(to name: String) -> Bool {
        Confirm.ask(Prefs.confirmProfile, title: "Switch to the profile “\(name)”?",
                    detail: "Its rules replace “\(activeProfile)”'s. The connection may restart for a moment.", confirm: "Switch")
    }
}
