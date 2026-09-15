import AppKit
import SwiftUI

/// macOS has its own charge limit (System Settings → Battery → Charging), so
/// OpenBattery points at it instead of shipping a privileged SMC helper: the
/// firmware keys that would be needed are locked even for root.
struct ChargeLimitSection: View {
    @State private var isExpanded = false

    private static let settingsURL =
        URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension")!

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 6) {
                Text("macOS can cap charging at 80, 85, 90 or 95%.")
                    .foregroundStyle(.secondary)
                step(1, "Open Battery settings.")
                step(2, "Click the ⓘ button next to **Charging**.")
                step(3, "Drag **Charge Limit** to the percentage you want.")
                Button("Open Battery Settings") {
                    NSWorkspace.shared.open(Self.settingsURL)
                }
                .controlSize(.small)
                .padding(.top, 2)
            }
            .font(.caption)
            .padding(.top, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text("Limit charging").font(.callout)
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(number).").monospacedDigit().foregroundStyle(.secondary)
            Text(.init(text))
        }
    }
}
