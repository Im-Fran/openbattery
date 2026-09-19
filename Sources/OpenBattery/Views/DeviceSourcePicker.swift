import SwiftUI

/// Chooses whose battery the window is showing: this Mac, or a device usbmuxd
/// can see. It sits above the tabs rather than inside them, because it changes
/// the subject of every tab at once.
struct DeviceSourcePicker: View {
    @EnvironmentObject private var monitor: BatteryMonitor
    @EnvironmentObject private var devices: DeviceMonitor

    var body: some View {
        HStack(spacing: 8) {
            Picker("Battery", selection: $devices.source) {
                Label("This Mac", systemImage: macSymbol)
                    .tag(DeviceMonitor.Source.mac)
                ForEach(devices.devices) { device in
                    Label(device.displayName, systemImage: Self.symbol(for: device))
                        .tag(DeviceMonitor.Source.device(udid: device.udid))
                }
            }
            // The label is the window's own subject; a visible "Battery:" in
            // front of it would only repeat the window title.
            .labelsHidden()
            // Bounded rather than fixed: a device names itself only once it has
            // been asked, and until then the widest menu item is a UDID.
            .frame(maxWidth: 240)
            .accessibilityLabel("Battery shown")
            // A pop-up offering one choice is not a choice.
            .disabled(devices.devices.isEmpty)

            Spacer(minLength: 8)
            status
                .font(.caption)
                .foregroundStyle(Color.subdued)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        // A rule, not a shadow: this is a toolbar-like strip, and the tabs below
        // draw their own background.
        .overlay(alignment: .bottom) { Divider() }
    }

    @ViewBuilder
    private var status: some View {
        if !devices.isSupported {
            // The one place someone can find out why their iPhone is not
            // listed. Said once, quietly, rather than in an alert.
            Text(DeviceError.isSandboxed ? "Not available in the App Store version"
                                         : "Can't reach connected devices")
        } else if let device = selectedDevice {
            Label(device.isNetwork ? "Wi-Fi" : "USB",
                  systemImage: device.isNetwork ? "wifi" : "cable.connector")
                .labelStyle(.titleAndIcon)
                // Hover help is invisible to anyone using the keyboard or
                // VoiceOver, so the model and version have a spoken path too.
                .help(subtitle(for: device))
                .accessibilityLabel(device.isNetwork ? "Connected over Wi-Fi" : "Connected by USB")
                .accessibilityValue(subtitle(for: device))
        } else if devices.devices.isEmpty {
            // Otherwise the strip is a dead control beside blank space, and the
            // feature is invisible to the person it was built for.
            Text("No devices connected")
        }
    }

    private var selectedDevice: DeviceIdentity? {
        guard case .device(let udid) = devices.source else { return nil }
        return devices.devices.first { $0.udid == udid }
    }

    /// The model and version belong here rather than in the picker's own row,
    /// where they would push the names of two devices out of sight.
    private func subtitle(for device: DeviceIdentity) -> String {
        [device.model, device.systemVersion.map { "iOS \($0)" }]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    /// A Mac Studio is not a laptop; the battery it does not have says so.
    private var macSymbol: String {
        monitor.snapshot.isPresent ? "laptopcomputer" : "desktopcomputer"
    }

    private static func symbol(for device: DeviceIdentity) -> String {
        guard let model = device.model else { return "iphone" }
        if model.hasPrefix("iPad") { return "ipad" }
        if model.hasPrefix("Watch") { return "applewatch" }
        return "iphone"
    }
}
