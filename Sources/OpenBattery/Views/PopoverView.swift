import ServiceManagement
import SwiftUI

struct PopoverView: View {
    @EnvironmentObject private var monitor: BatteryMonitor
    @Environment(\.openWindow) private var openWindow

    @AppStorage(MenuBarConfig.itemsKey) private var rawItems = MenuBarConfig.default.rawItems
    @AppStorage(MenuBarConfig.iconKey) private var showsIcon = MenuBarConfig.default.showsIcon
    @State private var settingsError: String?

    private var snapshot: BatterySnapshot { monitor.snapshot }

    /// Leading inset shared by text and separators, as in the system's own
    /// menu bar extras (Wi-Fi, Battery, Sound).
    private static let inset: CGFloat = 14

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
            VStack(alignment: .leading, spacing: 6) {
                ChargeLimitSection()
                if let settingsError {
                    // Colour lives on the icon; orange text fails contrast in light mode.
                    Label(settingsError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .symbolRenderingMode(.multicolor)
                }
            }
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
                    .tint(gaugeTint)
                    // The percentage above already says this.
                    .accessibilityHidden(true)
            }
        }
    }

    /// The colours of the system battery icon. The status text, the
    /// percentage and the Low Power label carry the same meaning in words.
    private var gaugeTint: Color {
        if snapshot.isCharging || (snapshot.isPluggedIn && snapshot.isFullyCharged) { return .green }
        if snapshot.lowPowerMode { return .yellow }
        if snapshot.percentage <= 20 && !snapshot.isPluggedIn { return .red }
        return .secondary
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
                if #available(macOS 14, *) {
                    NSApp.activate()
                } else {
                    NSApp.activate(ignoringOtherApps: true)
                }
                openWindow(id: BatteryInfoView.windowID)
            } label: {
                row("Battery Info…", shortcut: "⌘I")
            }
            .keyboardShortcut("i")
            settingsMenu
            Button { NSApp.terminate(nil) } label: {
                row("Quit OpenBattery", shortcut: "⌘Q")
            }
            .keyboardShortcut("q")
        }
        .buttonStyle(MenuRowButtonStyle())
    }

    /// A menu-item-like row: title leading, shortcut or chevron trailing.
    private func row(_ title: String, shortcut: String? = nil,
                     chevron: Bool = false) -> some View {
        HStack {
            Text(title)
            Spacer()
            if let shortcut {
                // Decorative: VoiceOver already announces `.keyboardShortcut`.
                Text(shortcut).foregroundStyle(.secondary).accessibilityHidden(true)
            }
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
    }

    private var settingsMenu: some View {
        Menu {
            Menu("Menu Bar") { menuBarOptions }
            Toggle("Launch at login", isOn: Binding(get: { launchesAtLogin },
                                                    set: setLaunchAtLogin(_:)))
        } label: {
            row("Settings", chevron: true)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
    }

    @ViewBuilder
    private var menuBarOptions: some View {
        Toggle("Battery icon", isOn: Binding(get: { config.effectiveShowsIcon },
                                             set: { showsIcon = $0 }))
        // The icon is forced back on when nothing else is left to show, so the
        // toggle says what is really happening.
        .disabled(config.items.isEmpty)
        Divider()
        ForEach(MenuBarItem.allCases) { item in
            Toggle(item.title, isOn: Binding(get: { config.contains(item) },
                                             set: { _ in apply(config.toggling(item)) }))
        }
    }

    // MARK: - Menu bar configuration

    private var config: MenuBarConfig {
        MenuBarConfig(showsIcon: showsIcon, rawItems: rawItems)
    }

    private func apply(_ config: MenuBarConfig) {
        rawItems = config.rawItems
        showsIcon = config.effectiveShowsIcon
    }

    // MARK: - Login item

    private var launchesAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            settingsError = nil
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            // Registration can "succeed" while still blocked on user approval.
            if SMAppService.mainApp.status == .requiresApproval {
                report("Allow OpenBattery in System Settings › General › Login Items.")
                SMAppService.openSystemSettingsLoginItems()
            }
        } catch {
            report("Couldn't change Launch at login. \(error.localizedDescription)")
        }
    }

    private func report(_ message: String) {
        settingsError = message
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
            .announcement: message,
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
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
