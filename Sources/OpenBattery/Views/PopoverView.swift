import SwiftUI

struct PopoverView: View {
    @EnvironmentObject private var monitor: BatteryMonitor
    @EnvironmentObject private var caffeine: CaffeineController
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    private var snapshot: BatterySnapshot { monitor.snapshot }

    /// Leading inset shared by text and separators, as in the system's own
    /// menu bar extras (Wi-Fi, Battery, Sound).
    private static let inset: CGFloat = 14

    /// Said once, so the spoken version cannot drift from the written one.
    private static let keepAwakeCost =
        "Keeping the display on uses more power and drains the battery faster."

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, Self.inset)
                .padding(.vertical, 12)
            separator
            power
                .padding(.horizontal, Self.inset)
                .padding(.vertical, 10)
            separator
            ChargeLimitSection()
            .padding(.horizontal, Self.inset)
            .padding(.vertical, 8)
            separator
            keepAwake
                .padding(.horizontal, Self.inset)
                .padding(.vertical, 8)
            separator
            // Row highlights sit 5 pt from the edge; their own 9 pt padding
            // lines the titles up with the text above.
            footer
                .padding(5)
        }
        .frame(width: 300)
        .onAppear { monitor.beginDetailUpdates() }
        .onDisappear { monitor.endDetailUpdates() }
    }

    private var separator: some View {
        Divider().padding(.horizontal, Self.inset)
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Battery").font(.headline)
                Spacer()
                if snapshot.lowPowerMode {
                    // Text alongside the leaf so colour is not the only cue.
                    Label("Low Power", systemImage: "leaf.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Low Power Mode on")
                        .help("Low Power Mode is on")
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(snapshot.isPresent ? "\(snapshot.percentage)%" : "—")
                    .font(.system(.largeTitle, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                VStack(alignment: .leading, spacing: 1) {
                    Text(snapshot.statusText)
                    if let capacity = snapshot.currentCapacityMAh {
                        Text(Fmt.mAh(capacity)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if snapshot.isPresent {
                Gauge(value: Double(snapshot.percentage), in: 0...100) { EmptyView() }
                    .gaugeStyle(.linearCapacity)
                    .tint(snapshot.chargeTint)
                    // The percentage above already says this.
                    .accessibilityHidden(true)
            }
        }
    }

    private var power: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Power")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            stat("Input", Fmt.watts(snapshot.adapterWatts))
            stat("Battery", Fmt.watts(snapshot.batteryWatts, signed: true))
            stat("System", Fmt.watts(snapshot.systemWatts))
            stat("Temperature", Fmt.celsius(snapshot.temperature))
        }
    }

    private var keepAwake: some View {
        VStack(alignment: .leading, spacing: 6) {
            // A switch, not a checkbox: it takes effect the moment it moves.
            // Bound through the controller so a rejected assertion snaps back.
            Toggle("Keep display awake", isOn: Binding(get: { caffeine.isActive },
                                                       set: caffeine.setActive))
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(.callout)
            // Colour lives on the icon; orange text fails contrast in light
            // mode. Full label colour, because a warning has to be readable.
            //
            // The triangle is earned only while the display is actually being
            // held on. With the switch off this is a description of what it
            // does, and a standing alarm for a state you are not in is how
            // people learn to ignore alarms.
            Label(Self.keepAwakeCost, systemImage: caffeine.isActive
                  ? "exclamationmark.triangle.fill" : "info.circle")
                .symbolRenderingMode(.multicolor)
                .font(.callout)
                // Take the width offered and grow downwards. Without this the
                // label is laid out at its ideal single-line width and the
                // warning is cut off mid-sentence.
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(caffeine.isActive ? "Warning. \(Self.keepAwakeCost)"
                                                      : Self.keepAwakeCost)
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).monospacedDigit().foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(value)
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Button {
                activate()
                openWindow(id: BatteryInfoView.windowID)
            } label: {
                row("Battery Info…", shortcut: "⌘I")
            }
            .keyboardShortcut("i")
            settingsButton
            Button { NSApp.terminate(nil) } label: {
                row("Quit OpenBattery", shortcut: "⌘Q")
            }
            .keyboardShortcut("q")
        }
        .buttonStyle(MenuRowButtonStyle())
    }

    /// A menu-item-like row: title leading, shortcut trailing.
    private func row(_ title: String, shortcut: String? = nil) -> some View {
        HStack {
            Text(title)
            Spacer()
            if let shortcut {
                // Decorative: VoiceOver already announces `.keyboardShortcut`.
                Text(shortcut).foregroundStyle(.secondary).accessibilityHidden(true)
            }
        }
    }

    private var settingsButton: some View {
        Button {
            activate()
            openSettings()
        } label: {
            row("Settings…", shortcut: "⌘,")
        }
        .keyboardShortcut(",")
    }

    /// A menu bar app is never frontmost, so its windows would open behind others.
    private func activate() {
        NSApp.activate()
    }
}

/// Full-width row with the rounded hover highlight of system menu bar extras.
private struct MenuRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Row(configuration: configuration)
    }

    private struct Row: View {
        let configuration: Configuration
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
                .padding(.horizontal, 9)
                .background {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(highlight)
                }
                .contentShape(Rectangle())
                .onHover { isHovered = $0 }
        }

        private var highlight: AnyShapeStyle {
            if configuration.isPressed { return AnyShapeStyle(.tertiary) }
            return isHovered ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear)
        }
    }
}
