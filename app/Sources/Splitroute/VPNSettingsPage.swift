import SwiftUI

/// Options that apply to every VPN protocol (OpenVPN now, others later).
struct VPNSettingsPage: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            if model.connError != nil {
                ServiceUnavailable()
            } else {
                Section {
                    SettingRow("Kill switch", description: "Not available yet.")
                }
            }
        }
    }
}
