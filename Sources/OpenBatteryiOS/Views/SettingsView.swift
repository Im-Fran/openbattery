import SwiftUI

/// iCloud sync, what it holds, and the app's details.
struct SettingsView: View {
    private static let repository = URL(string: "https://github.com/Im-Fran/openbattery")!

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    var body: some View {
        NavigationStack {
            List {
                CloudSyncSection { PhoneBatteryMonitor.shared.refresh(force: true) }
                SyncedDataSection()
                Section("About") {
                    LabeledContent("Version") {
                        Text(version).textSelection(.enabled)
                    }
                    LabeledContent("License", value: "MIT")
                    Link("Source Code", destination: Self.repository)
                    Link("Report an Issue", destination: Self.repository.appending(path: "issues/new"))
                }
            }
            .navigationTitle("Settings")
        }
    }
}
