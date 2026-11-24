import AppKit
import SwiftUI

/// The menu bar icon's panel. Not an NSPopover: a popover can't be made to appear over an app in full screen and its
/// corners are the system's. This is a borderless panel that never activates the app (so no Space switch), joins every
/// Space and sits above full-screen windows, with its own corner radius.
@MainActor
final class MenuBarPanel: NSObject {
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    static let cornerRadius: CGFloat = 12

    private let panel: Panel
    private weak var button: NSStatusBarButton?
    private var monitors: [Any] = []
    private var spaceObserver: NSObjectProtocol?

    var isShown: Bool { panel.isVisible }

    init<Content: View>(content: (@escaping (CGSize) -> Void) -> Content) {
        panel = Panel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
                      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        // Every Space, and over a full-screen app's Space too.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        let root = content { [weak self] size in self?.resize(to: size) }
            .clipShape(shape)
            .overlay(shape.stroke(Color.white.opacity(0.12), lineWidth: 1))
        panel.contentView = NSHostingView(rootView: root)
    }

    func show(relativeTo button: NSStatusBarButton) {
        guard !panel.isVisible, let window = button.window else { return }
        self.button = button
        if let host = panel.contentView { panel.setContentSize(host.fittingSize) }
        place()
        button.highlight(true)
        panel.makeKeyAndOrderFront(nil)
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        // A click in another app closes it; a click in this one closes it unless it is on the panel, a menu that came
        // from it, or the icon (whose own action toggles).
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: clicks) { [weak self] _ in
            Task { @MainActor in self?.close() }
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: clicks.union(.keyDown)) { [weak self] e in
            guard let self else { return e }
            if e.type == .keyDown {
                if e.keyCode == 53 { self.close(); return nil } // Esc
                return e
            }
            if let w = e.window, w === self.panel || self.panel.childWindows?.contains(w) == true || w === window { return e }
            if e.window?.parent === self.panel { return e }
            self.close()
            return e
        } as Any)
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }
    }

    func close() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        button?.highlight(false)
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors = []
        if let o = spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        spaceObserver = nil
    }

    /// The content changed size: follow it, keeping the top edge where it is.
    private func resize(to size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let top = panel.frame.maxY
        panel.setContentSize(size)
        if panel.isVisible { panel.setFrameTopLeftPoint(NSPoint(x: panel.frame.minX, y: top)) }
    }

    /// Under the icon, centered on it, kept on the screen.
    private func place() {
        guard let button, let window = button.window else { return }
        let icon = window.convertToScreen(button.convert(button.bounds, to: nil))
        let size = panel.frame.size
        let screen = window.screen ?? NSScreen.main
        var x = icon.midX - size.width / 2
        if let vis = screen?.visibleFrame { x = min(max(x, vis.minX + 6), vis.maxX - size.width - 6) }
        panel.setFrameTopLeftPoint(NSPoint(x: x, y: icon.minY - 4))
    }
}
