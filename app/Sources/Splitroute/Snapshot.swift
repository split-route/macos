#if DEBUG
import AppKit

/// Debug builds only: `--snapshot <dir>` renders every settings page, in light
/// and dark mode, to PNGs and quits. Run against a fake service with
/// SPLITROUTE_SOCKET to review the UI without root or screen recording.
@MainActor
func snapshotSettings(_ window: NSWindow, to dir: String) async {
    for (mode, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
        NSApp.appearance = NSAppearance(named: appearance)
        for page in Page.allCases {
            UserDefaults.standard.set(page.rawValue, forKey: "settingsPage")
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard let v = window.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { continue }
            v.cacheDisplay(in: v.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(page.rawValue)-\(mode).png"))
        }
    }
    NSApp.terminate(nil)
}

#endif
