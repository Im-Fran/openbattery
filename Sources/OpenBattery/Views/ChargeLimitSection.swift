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
        VStack(alignment: .leading, spacing: 0) {
            // ponytail: DisclosureGroup only toggles from its triangle on macOS,
            // so the whole row is the button and the chevron is ours to rotate.
            Button {
                withAnimation(.snappy(duration: 0.25)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Text("Limit charging").font(.callout)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isExpanded ? [.isButton, .isSelected] : .isButton)

            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    Text("macOS can cap charging at 80, 85, 90 or 95%.")
                        .foregroundStyle(.secondary)
                    step(1, "Open Battery settings.")
                    // The symbol, unlike a "ⓘ" glyph, is spoken by VoiceOver as "Info".
                    step(2, "Click the \(Image(systemName: "info.circle")) button next to **Charging**.")
                    step(3, "Drag **Charge Limit** to the percentage you want.")
                    Button("Open Battery Settings") {
                        NSWorkspace.shared.open(Self.settingsURL)
                    }
                    .controlSize(.small)
                    .padding(.top, 2)
                }
                .font(.callout)
                .padding(.top, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func step(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(number).").monospacedDigit().foregroundStyle(.secondary)
            Text(text)
        }
    }
}
