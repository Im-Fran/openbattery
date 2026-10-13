import SwiftData
import SwiftUI
import UIKit

/// The battery of the device in your hand: what iOS tells the app live, and
/// what a Mac read over a cable and left in iCloud, because iOS keeps health,
/// cycles and capacity from apps.
struct ThisDeviceView: View {
    private var monitor = PhoneBatteryMonitor.shared
    @Query(sort: \BatteryRecord.date, order: .reverse) private var records: [BatteryRecord]
    @AppStorage(SyncDevice.nameKey) private var customName = ""
    @State private var iCloudOn = FileManager.default.ubiquityIdentityToken != nil

    /// "iPhone" or "iPad", for copy that names the device.
    private let kind = UIDevice.current.model

    var body: some View {
        let device = SyncDevice.current
        let snapshot = monitor.snapshot
        // Sorted newest first, so the first match is this device's last save.
        let lastSaved = records.first { $0.deviceID == device.id }?.date
        let relayed = SyncedDevice.relayed(for: device, in: SyncedDevice.latest(from: records))

        NavigationStack {
            List {
                Section {
                    ThisDeviceHero(snapshot: snapshot)
                }

                Section("Status") {
                    ThisDeviceRow("Power Source", symbol: snapshot.isPluggedIn ? "powerplug" : "battery.100percent",
                                  value: snapshot.isPluggedIn ? "Power Adapter" : "Battery")
                    ThisDeviceRow("Low Power Mode", symbol: "leaf", value: snapshot.lowPowerMode ? "On" : "Off")
                    ThisDeviceRow("Temperature", symbol: "thermometer.medium", value: monitor.thermalState.label)
                }

                healthSection(relayed)

                Section {
                    if iCloudOn {
                        ThisDeviceRow("Last Saved", symbol: "icloud",
                                      value: lastSaved.map { Fmt.relative($0) } ?? "Not yet")
                    } else {
                        ThisDeviceRow("iCloud", symbol: "icloud.slash", value: "Off")
                    }
                    LabeledContent {
                        // The prompt is the name other devices see until one is
                        // typed, so it has to be readable, not placeholder grey.
                        TextField("Name", text: $customName,
                                  prompt: Text(UIDevice.current.name).foregroundStyle(.subdued))
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.words)
                            .submitLabel(.done)
                    } label: {
                        Label("Name", systemImage: "character.cursor.ibeam")
                    }
                } header: {
                    Text("iCloud")
                } footer: {
                    if iCloudOn {
                        Text("Your other devices list this \(kind) under this name. iOS only tells apps it's an “\(kind)”.")
                    } else {
                        Text(Self.iCloudOffFooter)
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .trackingICloudAccount($iCloudOn)
            .navigationTitle(device.name)
        }
    }

    static let iCloudOffFooter = "Sign in to iCloud in Settings to see your other devices."

    @ViewBuilder
    private func healthSection(_ relayed: SyncedDevice?) -> some View {
        if let relayed, let mac = relayed.device.relayedBy {
            let health = relayed.snapshot
            Section {
                ThisDeviceRow("Maximum Capacity", symbol: "heart", value: Fmt.percent(health.healthPercent, decimals: 0))
                ThisDeviceRow("Cycle Count", symbol: "arrow.trianglehead.2.clockwise", value: Fmt.integer(health.cycleCount))
                ThisDeviceRow("Full Charge Capacity", symbol: "battery.100percent", value: Fmt.mAh(health.fullChargeCapacityMAh))
                ThisDeviceRow("Design Capacity", symbol: "ruler", value: Fmt.mAh(health.designCapacityMAh))
            } header: {
                Text("Battery Health")
            } footer: {
                Text("Read by \(mac) \(Fmt.relative(relayed.date)).")
            }
        } else {
            Section("Battery Health") {
                Label {
                    Text("iOS doesn't share battery health with apps. Connect this \(kind) to a Mac running OpenBattery to read it.")
                        .foregroundStyle(.subdued)
                } icon: {
                    Image(systemName: "cable.connector")
                }
            }
        }
    }
}

/// The big reading at the top. Color backs up the words, never replaces them.
private struct ThisDeviceHero: View {
    let snapshot: BatterySnapshot
    @ScaledMetric(relativeTo: .largeTitle) private var numberSize: CGFloat = 64

    private var tint: Color { snapshot.heroTint }

    private var symbol: String {
        if snapshot.isCharging { return "bolt.fill" }
        if snapshot.isPluggedIn { return "powerplug.fill" }
        switch snapshot.percentage {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(snapshot.isPresent ? "\(snapshot.percentage)" : Fmt.unavailable)
                    .font(.system(size: numberSize, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("%")
                    .font(.title.weight(.semibold))
                    .foregroundStyle(.subdued)
            }

            Gauge(value: Double(snapshot.isPresent ? snapshot.percentage : 0), in: 0...100) {}
                .gaugeStyle(.linearCapacity)
                .tint(tint)

            // Stacked rather than side by side so neither truncates at large
            // Dynamic Type sizes.
            VStack(alignment: .leading, spacing: 4) {
                Label {
                    Text(snapshot.isPresent ? snapshot.statusText : "Reading unavailable")
                } icon: {
                    Image(systemName: symbol).foregroundStyle(tint)
                }
                if snapshot.lowPowerMode {
                    Label("Low Power Mode", systemImage: "leaf.fill")
                        .foregroundStyle(.subdued)
                }
            }
            .font(.headline)
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Battery")
        .accessibilityValue(spokenValue)
    }

    private var spokenValue: String {
        guard snapshot.isPresent else { return "Not available" }
        var parts = ["\(snapshot.percentage) percent", snapshot.statusText]
        if snapshot.lowPowerMode { parts.append("Low Power Mode") }
        return parts.joined(separator: ", ")
    }
}

/// A Settings-style row: symbol and name on the left, the reading on the right.
private struct ThisDeviceRow: View {
    let title: String
    let symbol: String
    let value: String

    init(_ title: String, symbol: String, value: String) {
        self.title = title
        self.symbol = symbol
        self.value = value
    }

    var body: some View {
        LabeledContent {
            Text(value)
                .foregroundStyle(.subdued)
                .accessibilityLabel(Fmt.spoken(value))
        } label: {
            Label(title, systemImage: symbol)
        }
    }
}
