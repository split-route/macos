import AppKit
import Design
import SwiftUI

/// The window: a sidebar with four pages. Every change is sent to the service
/// when it is made; there is no Apply.
struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("settingsPage") private var page: Destination = .tunnels


    var body: some View {
        HStack(spacing: 0) {
            // The traffic lights sit over the sidebar's top: the title bar is transparent.
            Sidebar(selection: $page, tunnels: [], title: "Splitroute", subtitle: "Smart VPN & Routing",
                    icon: NSApp.applicationIconImage.map { Image(nsImage: $0) }, topInset: 30,
                    status: model.connError == nil ? model.summary : nil, statusOn: model.health == .active)
            Group {
                switch page {
                case .tunnels: TunnelsPage()
                case .lists: ListsPage()
                case .status: StatusPage()
                case .settings: SettingsPage()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // The content is the darker, blurrier layer, so focus stays on it; the sidebar is lighter and clearer.
            .background(Backdrop(material: .hudWindow, darkness: 0.82))
        }
        .font(TypeScale.body)
        .foregroundStyle(Palette.ink.color)
        .preferredColorScheme(.dark)
        .ignoresSafeArea()
        .frame(minWidth: 820, minHeight: 520)
    }
}

/// Capsule search field; Liquid Glass on macOS 26+.
struct SearchField: View {
    @Binding var text: String
    var prompt = "Search…"

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(prompt, text: $text).textFieldStyle(.plain)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .modifier(CapsuleGlass())
    }
}

/// A soft fill and hairline so the field reads on any background, with Liquid Glass
/// on top on macOS 26+.
struct CapsuleGlass: ViewModifier {
    func body(content: Content) -> some View {
        let base = content
            .background(Capsule().fill(Color.primary.opacity(0.06)))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
        if #available(macOS 26, *) {
            base.glassEffect(.regular, in: Capsule())
        } else {
            base
        }
    }
}

/// Shown on pages that need the service when it can't be reached.
struct ServiceUnavailable: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Panel {
            if model.serviceNeedsApproval {
                FormRow("Allow the Splitroute service",
                        detail: "Turn on Splitroute under Allow in the Background in System Settings > General > Login Items. It changes routes, so it runs as a system service.",
                        error: model.actionError) {
                    Button("Open Login Items") { model.openLoginItems() }.buttonStyle(SolidButtonStyle())
                }
            } else if model.serviceNotStarting {
                FormRow("The Splitroute service isn't starting",
                        detail: model.appQuarantined
                            ? "macOS blocks it because the app is still marked as downloaded from the internet. In Terminal, run: xattr -dr com.apple.quarantine \(Bundle.main.bundlePath)"
                            : "It's allowed but launchd can't start it. Check it under Allow in the Background, and the log at /var/log/splitroute.log.",
                        error: model.actionError) {
                    Button("Open Login Items") { model.openLoginItems() }.buttonStyle(SolidButtonStyle())
                }
            } else {
                FormRow(model.connError?.localizedDescription ?? "Connecting to the service…",
                        detail: "Splitroute runs as a system service so it can change routes. You allow it once in System Settings > Login Items.",
                        error: model.actionError) {
                    if model.connError == .notRunning {
                        Button("Install service") { Task { await model.installService() } }
                            .buttonStyle(SolidButtonStyle()).disabled(model.busy)
                    }
                }
            }
        }
    }
}

extension AppModel {
    /// The service answers and its config is loaded.
    var ready: Bool { connError == nil && config != nil }
}
