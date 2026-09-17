import ServiceManagement
import SwiftUI

struct PopoverView: View {
    @EnvironmentObject private var monitor: BatteryMonitor
    @Environment(\.openWindow) private var openWindow

    @AppStorage(MenuBarConfig.itemsKey) private var rawItems = MenuBarConfig.default.rawItems
    @AppStorage(MenuBarConfig.iconKey) private var showsIcon = MenuBarConfig.default.showsIcon
    @State private var settingsError: String?

    private var snapshot: BatterySnapshot { monitor.snapshot }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            power
            Divider()
            ChargeLimitSection()
            if let settingsError {
                // Colour lives on the icon; orange text fails contrast in light mode.
                Label(settingsError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .symbolRenderingMode(.multicolor)
            }
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 300)
        .onAppear { monitor.beginDetailUpdates() }
        .onDisappear { monitor.endDetailUpdates() }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(snapshot.percentage)%")
                .font(.system(size: 30, weight: .medium, design: .rounded))
                .monospacedDigit()
            VStack(alignment: .leading, spacing: 2) {
                Text(snapshot.statusText)
                    .font(.callout)
                if let capacity = snapshot.currentCapacityMAh {
                    Text(Fmt.mAh(capacity)).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if snapshot.lowPowerMode {
                Image(systemName: "leaf.fill")
                    .foregroundStyle(.green)
                    .help("Low Power Mode is on")
            }
        }
    }

    private var power: some View {
        HStack(alignment: .top, spacing: 0) {
            stat("Input", Fmt.watts(snapshot.adapterWatts))
            stat("Battery", Fmt.watts(snapshot.batteryWatts, signed: true))
            stat("System", Fmt.watts(snapshot.systemWatts))
            stat("Temp", Fmt.celsius(snapshot.temperature), accessibilityTitle: "Temperature")
        }
    }

    /// `accessibilityTitle` spells out a title abbreviated to fit a quarter of the popover.
    private func stat(_ title: String, _ value: String,
                      accessibilityTitle: String? = nil) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.callout).monospacedDigit()
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityTitle ?? title)
        .accessibilityValue(value)
    }

    private var footer: some View {
        HStack {
            Button("Battery Info…") {
                if #available(macOS 14, *) {
                    NSApp.activate()
                } else {
                    NSApp.activate(ignoringOtherApps: true)
                }
                openWindow(id: BatteryInfoView.windowID)
            }
            .keyboardShortcut("i")
            Spacer()
            settingsMenu
            Button("Quit OpenBattery") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .controlSize(.small)
    }

    private var settingsMenu: some View {
        Menu {
            Menu("Menu Bar") { menuBarOptions }
            Toggle("Launch at login", isOn: Binding(get: { launchesAtLogin },
                                                    set: setLaunchAtLogin(_:)))
        } label: {
            Label("Settings", systemImage: "gearshape")
                .labelStyle(.iconOnly)
                // Keep the hit target at the 20 pt macOS minimum.
                .frame(minWidth: 20, minHeight: 20)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Settings")
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
