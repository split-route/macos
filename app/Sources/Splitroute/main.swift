import AppKit
import Combine
import Design
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let model = AppModel()
    private var item: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var menuPanel: MenuBarPanel!
    private var bag = Set<AnyCancellable>()
    private var launchedAtLogin = false

    // The launch Apple event is only available here, not in didFinishLaunching.
    func applicationWillFinishLaunching(_ notification: Notification) {
        let e = NSAppleEventManager.shared().currentAppleEvent
        launchedAtLogin = e?.eventID == kAEOpenApplication
            && e?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        removeQuarantine()
    }

    /// A DMG copied by hand keeps the browser's quarantine flag on every file,
    /// and launchd then refuses to start the bundled service binary (it isn't
    /// notarized: no Developer ID). macOS only runs the app at all after the user
    /// allowed it ("Open Anyway"), so clear the flag on our own bundle, as the
    /// Homebrew cask does. A new download arrives quarantined again. Fails quietly
    /// if the bundle isn't writable; the service page then shows the command.
    private func removeQuarantine() {
        let root = Bundle.main.bundlePath
        let name = "com.apple.quarantine"
        guard getxattr(root, name, nil, 0, 0, XATTR_NOFOLLOW) >= 0 else { return }
        var paths = [root]
        if let e = FileManager.default.enumerator(atPath: root) {
            for case let rel as String in e { paths.append(root + "/" + rel) }
        }
        for p in paths { removexattr(p, name, XATTR_NOFOLLOW) }
    }

    /// Opening the app again (Spotlight, Finder, Dock, `open`) while it runs shows the window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Fonts.register()
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        menuPanel = MenuBarPanel { onSize in
            MenuPopover(
                openApp: { [weak self] page in self?.menuPanel.close(); self?.show(page: page) },
                quit: { [weak self] in self?.menuPanel.close(); self?.quit() },
                onSize: onSize
            ).environmentObject(self.model)
        }
        model.$status.combineLatest(model.$connError)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in self?.updateIcon() }
            .store(in: &bag)
        updateIcon()
        installMainMenu()
        unfocusFieldsOnOutsideClick()
        // Opened by the user (Spotlight, Finder, `open`): show the window. At login
        // only the menu bar icon appears.
        if !launchedAtLogin || CommandLine.arguments.contains("--settings") { openSettings() }
        #if DEBUG
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            openSettings()
            let pop = AnyView(MenuPopover(openApp: { _ in }, quit: {}).environmentObject(model))
            Task { if let w = settingsWindow { await snapshotSettings(w, model: model, popover: pop, to: args[i + 1]) } }
        }
        // `--page lists` opens the window on that page (window captures for UI review).
        if let i = args.firstIndex(of: "--page"), i + 1 < args.count, let p = Destination(rawValue: args[i + 1]) {
            openSettings()
            UserDefaults.standard.set(p.rawValue, forKey: "settingsPage")
        }
        #endif
    }

    private func updateIcon() {
        let color: NSColor
        switch model.health {
        case .active: color = .systemGreen
        case .problem: color = .systemOrange
        case .idle: color = .systemGray
        case .notRunning: color = .systemRed
        }
        item.button?.image = menuBarIcon(dot: color)
        item.button?.toolTip = "Splitroute: \(model.summary)"
    }

    @objc private func togglePopover() {
        guard let button = item.button else { return }
        if menuPanel.isShown { return menuPanel.close() }
        // The default route in the panel comes from the config, which the window normally loads.
        Task { await model.loadSettings() }
        menuPanel.show(relativeTo: button)
    }

    private func action(_ title: String, _ sel: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        i.target = self
        return i
    }

    private static let quitActionKey = "quitAction" // "turnOff" or "keep", once "Don't ask again" was checked

    /// Quitting only removes the icon; the service keeps its tunnels up. While one
    /// is connected, ask whether to disconnect first so it doesn't stay on unseen.
    @objc private func quit() {
        guard model.health == .active else { return NSApp.terminate(nil) }
        let d = UserDefaults.standard
        var turnOff: Bool
        switch d.string(forKey: Self.quitActionKey) {
        case "turnOff": turnOff = true
        case "keep": turnOff = false
        default:
            let alert = NSAlert()
            alert.messageText = "The connection is still on."
            alert.informativeText = "It stays on after you quit. Open Splitroute again to turn it off later."
            alert.addButton(withTitle: "Turn Off and Quit")
            alert.addButton(withTitle: "Quit")
            alert.addButton(withTitle: "Cancel")
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Don't ask again"
            NSApp.activate(ignoringOtherApps: true)
            let r = alert.runModal()
            if r == .alertThirdButtonReturn { return }
            turnOff = r == .alertFirstButtonReturn
            if alert.suppressionButton?.state == .on { d.set(turnOff ? "turnOff" : "keep", forKey: Self.quitActionKey) }
        }
        guard turnOff else { return NSApp.terminate(nil) }
        Task {
            await model.setVPN(false)
            if !model.vpnOn { return NSApp.terminate(nil) }
            // Never quit over a failure: the VPN would stay on with no icon.
            let alert = NSAlert()
            alert.messageText = "Couldn't disconnect."
            alert.informativeText = model.actionError ?? model.summary
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    @objc private func openSettings() { show(page: nil) }

    /// Opens the window, on `page` when given, else on Home (the first page).
    private func show(page: Destination?) {
        if settingsWindow == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 920, height: 640),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false)
            w.title = "Splitroute"
            // The sidebar runs to the top edge, under the traffic lights.
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            // The window is dark glass: it keeps the dark look whatever the system uses.
            w.appearance = NSAppearance(named: .darkAqua)
            w.backgroundColor = .clear
            w.isOpaque = false
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.contentViewController = NSHostingController(rootView: SettingsView().environmentObject(model))
            w.setContentSize(NSSize(width: 920, height: 640))
            w.center()
            w.setFrameAutosaveName("Settings2")
            w.contentMinSize = NSSize(width: 820, height: 520)
            settingsWindow = w
        }
        if let page {
            UserDefaults.standard.set(page.rawValue, forKey: "settingsPage")
        } else if settingsWindow?.isVisible != true {
            UserDefaults.standard.set(Destination.home.rawValue, forKey: "settingsPage")
        }
        model.settingsVisible = true
        Task { await model.loadSettings() }
        // A menu bar app (LSUIElement) is left out of Cmd+Tab and the Dock. Become a
        // regular app while the window is open, and go back to menu bar only on close.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
        // Don't start in the search field; the user clicks it to search.
        DispatchQueue.main.async { self.settingsWindow?.makeFirstResponder(nil) }
    }

    func windowWillClose(_ notification: Notification) {
        model.settingsVisible = false
        NSApp.setActivationPolicy(.accessory)
    }

    /// A click outside the text field being edited ends the editing, like in
    /// System Settings: clicking a sidebar item leaves the search field. Only
    /// single-line fields (field editors); a multi-line editor keeps focus.
    private func unfocusFieldsOnOutsideClick() {
        NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { e in
            guard let w = e.window, let editor = w.firstResponder as? NSTextView, editor.isFieldEditor,
                  let field = editor.delegate as? NSView else { return e }
            if !field.bounds.contains(field.convert(e.locationInWindow, from: nil)) {
                w.makeFirstResponder(nil)
            }
            return e
        }
    }

    /// Shown only while the window is open (regular policy): Quit goes through the
    /// routing prompt, and Edit makes Cmd+C/V/X/A/Z work in text fields.
    private func installMainMenu() {
        let main = NSMenu()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Splitroute", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Splitroute", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(action("Quit Splitroute", #selector(quit), key: "q"))
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        for sub in [appMenu, edit, window] {
            let item = NSMenuItem()
            item.submenu = sub
            main.addItem(item)
        }
        NSApp.mainMenu = main
        NSApp.windowsMenu = window
    }
}

/// The branch symbol in the menu bar's text color, with a status dot in the
/// bottom-right corner. Drawn on demand so it follows light and dark menu bars;
/// not a template image, because a template would lose the dot's color.
func menuBarIcon(dot: NSColor) -> NSImage {
    let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        if let sym = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: "Splitroute")?
            .withSymbolConfiguration(cfg) {
            let s = sym.size
            let r = NSRect(x: (16 - s.width) / 2, y: 2 + (16 - s.height) / 2, width: s.width, height: s.height)
            sym.draw(in: r)
            NSColor.labelColor.set()
            r.fill(using: .sourceAtop)
        }
        let dotRect = NSRect(x: 11, y: 0.5, width: 7, height: 7)
        // Cut a gap around the dot so it reads on any menu bar background.
        NSGraphicsContext.current?.compositingOperation = .clear
        NSBezierPath(ovalIn: dotRect.insetBy(dx: -1.5, dy: -1.5)).fill()
        NSGraphicsContext.current?.compositingOperation = .sourceOver
        dot.set()
        NSBezierPath(ovalIn: dotRect).fill()
        return true
    }
    img.isTemplate = false
    return img
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
