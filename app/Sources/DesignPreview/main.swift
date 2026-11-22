import AppKit
import Design
import SwiftUI

// Fake data only. Run `DesignPreview --snapshot <dir>` to write PNGs, or without
// arguments to open the interactive window.

let office = TunnelItem(id: "office", name: "Office", detail: "OpenVPN, 185.12.40.9", line: .cobalt, state: .connected)
let home = TunnelItem(id: "home", name: "Home", detail: "OpenVPN, 94.101.7.22", line: .pine, state: .connecting)
let labs = TunnelItem(id: "labs", name: "Research lab", detail: "OpenVPN, 10.30.0.1", line: .saffron, state: .needsAuth)
let edge = TunnelItem(id: "edge", name: "Edge", detail: "OpenVPN, 51.15.8.130", line: .signal,
                      state: .failed("Authentication failed. Check your username and password, then retry."))
let spare = TunnelItem(id: "spare", name: "Spare", detail: "OpenVPN, 203.0.113.8", line: .plum, state: .off)

let normalTunnels = [office, home]
let allStates = [office, home, labs, edge, spare]

let normalLists = [
    ListItem(id: "ir", name: "Iran IP ranges", note: "1,284 entries", action: .direct),
    ListItem(id: "social", name: "Social networks", note: "312 entries", action: .tunnel, tunnelID: "office"),
    ListItem(id: "ads", name: "Ads and trackers", note: "48,201 entries", action: .block),
    ListItem(id: "work", name: "Work tools", note: "86 entries", action: .tunnel, tunnelID: "home"),
    ListItem(id: "stream", name: "Streaming", note: "540 entries", action: .tunnel, tunnelID: "office"),
]

let stressLists = [
    ListItem(id: "long", name: "Every domain our legal department has ever asked us to treat carefully",
             note: "12,480 entries", action: .tunnel, tunnelID: "labs"),
    ListItem(id: "imp", name: "Community ad list", note: "Imported from a URL, last good copy from Nov 20", action: .block,
             problem: "Download failed: the server returned 404. Still using the copy from Nov 20."),
    normalLists[0], normalLists[1],
]

let activity = [
    ActivityItem(time: "14:02", text: "Home is connecting"),
    ActivityItem(time: "14:02", text: "Office connected"),
    ActivityItem(time: "14:01", text: "Edge failed: authentication failed", isError: true),
    ActivityItem(time: "13:58", text: "Updated Iran IP ranges (1,284 entries)"),
    ActivityItem(time: "13:58", text: "Could not download Community ad list: the server returned 404", isError: true),
]

@MainActor func render<V: View>(_ view: V, size: CGSize, dark: Bool, to url: URL) {
    var size = size
    if size.height == 0 {  // fit the content (the popover)
        size.height = NSHostingView(rootView: view.frame(width: size.width)).fittingSize.height
    }
    let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
    host.frame = NSRect(origin: .zero, size: size)
    let win = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: size.width, height: size.height),
                       styleMask: [.borderless], backing: .buffered, defer: false)
    win.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    win.contentView = host
    win.orderBack(nil)
    host.layoutSubtreeIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.6))
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
    host.cacheDisplay(in: host.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])?.write(to: url)
}

@MainActor func snapshots(to dir: String) {
    let win = CGSize(width: 900, height: 600)
    let pop = CGSize(width: 340, height: 0)
    let shots: [(String, AnyView, CGSize)] = [
        ("tunnels-normal", AnyView(AppWindow(page: .tunnels, tunnels: normalTunnels, lists: normalLists, activity: activity)), win),
        ("tunnels-states", AnyView(AppWindow(page: .tunnels, tunnels: allStates, lists: normalLists, activity: activity)), win),
        ("tunnels-empty", AnyView(AppWindow(page: .tunnels, tunnels: [], lists: [], activity: activity)), win),
        ("lists-normal", AnyView(AppWindow(page: .lists, tunnels: normalTunnels, lists: normalLists, activity: activity)), win),
        ("lists-stress", AnyView(AppWindow(page: .lists, tunnels: allStates, lists: stressLists, activity: activity)), win),
        ("lists-focus", AnyView(AppWindow(page: .lists, tunnels: normalTunnels, lists: normalLists, activity: activity, focusFirstList: true)), win),
        ("lists-empty", AnyView(AppWindow(page: .lists, tunnels: normalTunnels, lists: [], activity: activity)), win),
        ("status", AnyView(AppWindow(page: .status, tunnels: normalTunnels, lists: normalLists, activity: activity)), win),
        ("settings", AnyView(AppWindow(page: .settings, tunnels: normalTunnels, lists: normalLists, activity: activity)), win),
        ("popover-normal", AnyView(Popover(tunnels: normalTunnels, lists: normalLists)), pop),
        ("popover-states", AnyView(Popover(tunnels: allStates, lists: normalLists)), pop),
        ("popover-empty", AnyView(Popover(tunnels: [], lists: [])), pop),
    ]
    for (mode, dark) in [("light", false), ("dark", true)] {
        for (name, view, size) in shots {
            render(view, size: size, dark: dark, to: URL(fileURLWithPath: dir).appendingPathComponent("\(name)-\(mode).png"))
        }
    }
}

let app = NSApplication.shared
Fonts.register()
let args = CommandLine.arguments
if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
    app.setActivationPolicy(.prohibited)
    MainActor.assumeIsolated { snapshots(to: args[i + 1]) }
} else {
    app.setActivationPolicy(.regular)
    let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                     styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                     backing: .buffered, defer: false)
    w.titlebarAppearsTransparent = true
    w.contentView = NSHostingView(rootView: AppWindow(page: .tunnels, tunnels: allStates, lists: stressLists, activity: activity))
    w.center(); w.makeKeyAndOrderFront(nil)
    app.activate(ignoringOtherApps: true)
    app.run()
}
