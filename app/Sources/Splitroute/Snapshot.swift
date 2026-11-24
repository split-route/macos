#if DEBUG
import AppKit
import Design
import SwiftUI

/// Debug builds only: `--snapshot <dir>` renders every window page and the menu bar
/// popover, in light and dark mode, to PNGs and quits. Run against a fake service
/// with SPLITROUTE_SOCKET to review the UI without root or screen recording.
@MainActor
func snapshotSettings(_ window: NSWindow, model: AppModel, popover: AnyView, to dir: String) async {
    // SPLITROUTE_SNAPSHOT_TALL=1: a tall window, to see a long page in one picture.
    if ProcessInfo.processInfo.environment["SPLITROUTE_SNAPSHOT_TALL"] != nil {
        window.setContentSize(NSSize(width: 920, height: 2400))
    }
    for (mode, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
        NSApp.appearance = NSAppearance(named: appearance)
        for page in Destination.allCases {
            UserDefaults.standard.set(page.rawValue, forKey: "settingsPage")
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard let v = window.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { continue }
            v.cacheDisplay(in: v.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(page.rawValue)-\(mode).png"))
        }
        // The popover's content, in a window of its own.
        let host = NSHostingView(rootView: popover)
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)
        let w = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.contentView = host
        w.orderBack(nil)
        host.layoutSubtreeIfNeeded()
        try? await Task.sleep(nanoseconds: 400_000_000)
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: dir).appendingPathComponent("popover-\(mode).png"))
        }
        w.orderOut(nil)
        // The import sheet, in the states a person meets.
        let sheets: [(String, AnyView)] = [
            ("import-links", AnyView(ImportTunnelsSheet(openProfile: { _ in }, text: "vless://b831381d-6324-4d53-ad4f-8cda48b30811@example.com:443?security=tls#Alpha\ntrojan://pw@example.org:443#Beta").environmentObject(model))),
            ("import-address", AnyView(ImportTunnelsSheet(openProfile: { _ in }, text: "https://panel.example.com/sub/8f2c0c1e").environmentObject(model))),
            ("import-done", AnyView(ImportTunnelsSheet(openProfile: { _ in }, result: AddResult(
                added: 38, skipped: [SkippedNode(label: "🇩🇪 Frankfurt xhttp", reason: "transport \"xhttp\" isn't supported by the engine"),
                                     SkippedNode(label: "hysteria2://…", reason: "certificate pinning (pinSHA256) isn't supported: refusing to connect without it")],
                group: "Provider")).environmentObject(model))),
            ("import-none", AnyView(ImportTunnelsSheet(openProfile: { _ in }, result: AddResult(
                added: 0, skipped: [SkippedNode(label: "Clash node", reason: "VLESS encryption (the encryption= parameter) isn't supported")], group: nil)).environmentObject(model))),
        ]
        for (name, view) in sheets {
            let h = NSHostingView(rootView: view)
            h.frame = NSRect(origin: .zero, size: h.fittingSize)
            let sw = NSWindow(contentRect: h.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            sw.contentView = h
            sw.orderBack(nil)
            h.layoutSubtreeIfNeeded()
            try? await Task.sleep(nanoseconds: 300_000_000)
            if let rep = h.bitmapImageRepForCachingDisplay(in: h.bounds) {
                h.cacheDisplay(in: h.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name)-\(mode).png"))
            }
            sw.orderOut(nil)
        }
    }
    NSApp.terminate(nil)
}

#endif
