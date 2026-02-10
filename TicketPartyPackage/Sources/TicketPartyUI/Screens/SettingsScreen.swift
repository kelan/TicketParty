import SwiftUI

public struct TicketPartySettingsView: View {
    public init() {}

    public var body: some View {
        Form {
            Section("General") {
                LabeledContent("Theme", value: "System")
                LabeledContent("Notifications", value: "Enabled")
            }

            Section("Integrations") {
                LabeledContent("Sync Provider", value: "Not Configured")
                LabeledContent("Issue Tracker", value: "Not Configured")
            }

            Section("Diagnostics") {
                LabeledContent("Environment", value: "Stub")
                LabeledContent("Build", value: "Debug")
            }
        }
        .padding(16)
        .frame(minWidth: 560, minHeight: 360)
    }
}
