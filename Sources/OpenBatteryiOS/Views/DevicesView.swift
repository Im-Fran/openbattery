import SwiftData
import SwiftUI

/// Every Mac, iPhone and iPad on the iCloud account, newest reading each.
///
/// A split view rather than a stack: on iPad the list stays beside the
/// detail, and on iPhone it collapses into the same push navigation a stack
/// would give.
struct DevicesView: View {
    // ponytail: fetches the whole history (30 days × every device) to pick the
    // newest of each; a per-device fetch limit if the list ever feels slow.
    @Query(sort: \BatteryRecord.date, order: .reverse) private var records: [BatteryRecord]
    @Environment(\.modelContext) private var modelContext
    @State private var selection: String?
    @State private var iCloudOn = FileManager.default.ubiquityIdentityToken != nil

    var body: some View {
        let devices = SyncedDevice.listed(records: records, live: Array(LiveLink.shared.peers.values),
                                          liveRelayed: LiveLink.shared.relayed)
        NavigationSplitView {
            Group {
                // Devices win over the iCloud check: what is already in the
                // store is still worth showing, and the signed-out simulator
                // keeps its `-demoData` devices.
                if devices.isEmpty && !iCloudOn {
                    ContentUnavailableView("iCloud Is Off", systemImage: "icloud.slash",
                                           description: Text(ThisDeviceView.iCloudOffFooter))
                } else if devices.isEmpty {
                    ContentUnavailableView {
                        Label("No Devices Yet", systemImage: "macbook.and.iphone")
                    } description: {
                        Text("Install OpenBattery on your Mac and sign in to the same iCloud account. Its battery shows up here, along with any iPhone or iPad it reads.")
                    }
                } else {
                    DeviceList(devices: devices, selection: $selection)
                }
            }
            .navigationTitle("Devices")
        } detail: {
            if let selection {
                DeviceDetailView(deviceID: selection).id(selection)
            } else {
                ContentUnavailableView("Select a Device", systemImage: "battery.100percent",
                                       description: Text("Pick a device to see its charge history."))
            }
        }
        .trackingICloudAccount($iCloudOn)
        .task {
            #if DEBUG
            DemoData.seedIfRequested(into: modelContext)
            #endif
        }
    }
}

private struct DeviceList: View {
    let devices: [SyncedDevice]
    @Binding var selection: String?

    var body: some View {
        let currentID = SyncDevice.current.id
        let macs = devices.filter { $0.device.kind == .mac }
        let mobile = devices.filter { $0.device.kind != .mac }
        // Once a minute is enough to keep "5 minutes ago" and the stale cue
        // honest without a reading arriving.
        TimelineView(.everyMinute) { context in
            List(selection: $selection) {
                if !macs.isEmpty {
                    Section("Macs") { rows(macs, currentID: currentID, now: context.date) }
                }
                if !mobile.isEmpty {
                    Section("iPhones & iPads") { rows(mobile, currentID: currentID, now: context.date) }
                }
            }
        }
    }

    private func rows(_ devices: [SyncedDevice], currentID: String, now: Date) -> some View {
        ForEach(devices) { device in
            NavigationLink(value: device.id) {
                DeviceRow(device: device, isCurrent: device.id == currentID, now: now)
            }
        }
    }
}

private struct DeviceRow: View {
    let device: SyncedDevice
    let isCurrent: Bool
    let now: Date

    @Environment(\.dynamicTypeSize) private var typeSize

    private var snapshot: BatterySnapshot { device.snapshot }
    private var isStale: Bool { !device.isLive && device.isStale(at: now) }

    /// "This iPhone" for the phone in hand, "Via MacBook Pro" for one a Mac
    /// read over a cable, so a reading is never mistaken for a live one.
    private var origin: String? {
        if isCurrent { return device.device.kind == .iPad ? "This iPad" : "This iPhone" }
        return device.device.relayedBy.map { "Via \($0)" }
    }

    /// "On battery · 21 min ago": one line instead of two keeps rows short.
    private var subtitle: String {
        "\(snapshot.listStatus) · \(device.isLive ? "Live" : device.freshness(at: now))"
    }

    var body: some View {
        // At accessibility sizes a row side by side leaves each column a few
        // letters wide; stacked, every line gets the full width, and the
        // device icon gives its room to the text.
        let stacked = typeSize.isAccessibilitySize
        let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
                             : AnyLayout(HStackLayout(spacing: 12))
        layout {
            if !stacked {
                Image(systemName: device.device.symbol)
                    .font(.title2)
                    .foregroundStyle(isStale ? Color.secondary : Color.accentColor)
                    .frame(minWidth: 36)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(device.device.name)
                    .font(.headline)
                    .foregroundStyle(isStale ? .subdued : .primary)
                if let origin {
                    Text(origin)
                        .font(.subheadline)
                        .foregroundStyle(.subdued)
                }
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.subdued)
            }

            if !stacked {
                Spacer(minLength: 8)
            }

            HStack(spacing: 6) {
                Text("\(snapshot.percentage)%")
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(isStale ? .subdued : .primary)
                Image(systemName: snapshot.batterySymbol)
                    .foregroundStyle(isStale ? Color.secondary : snapshot.chargeTint)
            }
            .accessibilityHidden(true)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([device.device.name, origin].compactMap { $0 }.joined(separator: ", "))
        .accessibilityValue("\(snapshot.percentage) percent, \(snapshot.listStatus), \(device.freshness(at: now))")
    }
}

extension View {
    /// Keeps `isOn` in step with whether anyone is signed in to iCloud: the
    /// account can change in Settings while the app sits in the background.
    func trackingICloudAccount(_ isOn: Binding<Bool>) -> some View {
        modifier(ICloudAccountTracker(isOn: isOn))
    }
}

private struct ICloudAccountTracker: ViewModifier {
    @Binding var isOn: Bool
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { refresh() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .NSUbiquityIdentityDidChange)) { _ in refresh() }
    }

    private func refresh() { isOn = FileManager.default.ubiquityIdentityToken != nil }
}

extension SyncedDevice {
    /// An hour without a reading means the device is asleep, away from its
    /// Mac, or off iCloud: past that, the number is history, not a reading.
    func isStale(at now: Date) -> Bool { now.timeIntervalSince(date) > 3600 }

    /// "21 min ago" after the status it follows; "Last seen 3 hr ago" once
    /// stale, so an old number is never read as a current one.
    func freshness(at now: Date) -> String {
        let ago = now.timeIntervalSince(date) < 60
            ? "just now"
            : date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated).locale(Fmt.dateLocale))
        return isStale(at: now) ? "Last seen \(ago)" : ago
    }
}

extension BatterySnapshot {
    /// The system battery glyph nearest the charge, with a bolt while charging.
    var batterySymbol: String {
        if isCharging { return "battery.100percent.bolt" }
        switch percentage {
        case 88...: return "battery.100percent"
        case 63..<88: return "battery.75percent"
        case 38..<63: return "battery.50percent"
        case 13..<38: return "battery.25percent"
        default: return "battery.0percent"
        }
    }

    /// `statusText` without the time estimate, which goes stale the moment
    /// it is synced; Low Power Mode said in words, not only in yellow.
    var listStatus: String {
        let state: String
        if isCharging { state = "Charging" }
        else if isFullyCharged && isPluggedIn { state = "Fully charged" }
        else if isPluggedIn { state = "Plugged in, not charging" }
        else { state = "On battery" }
        return lowPowerMode ? "\(state) · Low Power Mode" : state
    }
}
