import SwiftUI
import WidgetKit

@main
struct OpenBatteryWidgets: WidgetBundle {
    var body: some Widget {
        BatteriesWidget()
    }
}

/// The charge of every device on the iCloud account, like the system's own
/// Batteries widget, but with the Macs in it.
struct BatteriesWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "Batteries", provider: Provider()) { entry in
            BatteriesView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Batteries")
        .description("The charge of your Macs, iPhones and iPads.")
        .supportedFamilies(Self.families)
    }

    private static var families: [WidgetFamily] {
        #if os(iOS)
        [.systemSmall, .systemMedium, .systemLarge, .accessoryCircular, .accessoryRectangular, .accessoryInline]
        #else
        [.systemSmall, .systemMedium, .systemLarge]
        #endif
    }
}

struct Entry: TimelineEntry {
    let date: Date
    let devices: [WidgetDevice]
}

/// The apps write the list and reload the widgets whenever it changes, so
/// the timeline only has to re-read it now and then — for the stale cue.
struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry {
        Entry(date: .now, devices: Self.sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        let devices = WidgetDevice.read()
        // The gallery shows the snapshot before anything was ever written.
        completion(Entry(date: .now, devices: devices.isEmpty && context.isPreview ? Self.sample : devices))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        let now = Date.now
        completion(Timeline(entries: [Entry(date: now, devices: WidgetDevice.read())],
                            policy: .after(now.addingTimeInterval(15 * 60))))
    }

    static let sample = [
        WidgetDevice(id: "iphone", name: "iPhone", symbol: "iphone", percentage: 76, isCharging: true,
                     isPluggedIn: true, lowPowerMode: false, date: .now, isCurrent: true),
        WidgetDevice(id: "mac", name: "MacBook Pro", symbol: "laptopcomputer", percentage: 58, isCharging: false,
                     isPluggedIn: false, lowPowerMode: false, date: .now, isCurrent: false),
        WidgetDevice(id: "ipad", name: "iPad", symbol: "ipad", percentage: 31, isCharging: false,
                     isPluggedIn: false, lowPowerMode: true, date: .now, isCurrent: false),
    ]
}

// MARK: - Views

struct BatteriesView: View {
    let entry: Entry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if entry.devices.isEmpty {
            empty
        } else {
            switch family {
            case .systemSmall: small
            case .systemMedium: medium
            case .systemLarge: large
            #if os(iOS)
            case .accessoryCircular: DeviceGauge(device: entry.devices[0], now: entry.date)
            case .accessoryRectangular: rectangular
            case .accessoryInline: inline
            #endif
            default: medium
            }
        }
    }

    private var empty: some View {
        Text("Open OpenBattery to see your devices.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
    }

    /// Four rings, as the system's Batteries widget lays them out.
    private var small: some View {
        Grid(horizontalSpacing: 12, verticalSpacing: 12) {
            let devices = Array(entry.devices.prefix(4))
            ForEach(0..<(devices.count + 1) / 2, id: \.self) { row in
                GridRow {
                    ForEach(devices[(row * 2)..<min(row * 2 + 2, devices.count)]) { device in
                        VStack(spacing: 4) {
                            DeviceGauge(device: device, now: entry.date)
                            Text("\(device.percentage)%")
                                .font(.caption.weight(.semibold))
                                .monospacedDigit()
                                .accessibilityHidden(true)
                        }
                    }
                }
            }
        }
    }

    private var medium: some View {
        HStack(alignment: .top, spacing: 8) {
            ForEach(entry.devices.prefix(4)) { device in
                VStack(spacing: 6) {
                    DeviceGauge(device: device, now: entry.date)
                    Text("\(device.percentage)%")
                        .font(.headline)
                        .monospacedDigit()
                    Text(device.name)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(device.spoken(at: entry.date))
            }
        }
    }

    private var large: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(entry.devices.prefix(6)) { device in
                HStack(spacing: 10) {
                    Image(systemName: device.symbol)
                        .font(.title3)
                        .frame(width: 28)
                        .foregroundStyle(device.tint)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(device.name).font(.subheadline.weight(.medium)).lineLimit(1)
                            Spacer(minLength: 4)
                            if device.isCharging {
                                Image(systemName: "bolt.fill").font(.caption).foregroundStyle(.green)
                            }
                            Text("\(device.percentage)%").font(.subheadline.weight(.semibold)).monospacedDigit()
                        }
                        ProgressView(value: Double(device.percentage), total: 100)
                            .tint(device.tint)
                    }
                }
                .opacity(device.isStale(at: entry.date) ? 0.5 : 1)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(device.spoken(at: entry.date))
            }
            Spacer(minLength: 0)
        }
    }

    #if os(iOS)
    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(entry.devices.prefix(3)) { device in
                HStack(spacing: 4) {
                    Image(systemName: device.symbol).frame(width: 18)
                    Text("\(device.percentage)%").monospacedDigit()
                    if device.isCharging { Image(systemName: "bolt.fill") }
                }
                .font(.headline)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(device.spoken(at: entry.date))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var inline: some View {
        let device = entry.devices[0]
        return Label("\(device.percentage)%", systemImage: device.isCharging ? "bolt.fill" : device.symbol)
    }
    #endif
}

/// A ring filled to the charge, the device's symbol inside, and a bolt while it
/// charges: the charging state is never colour alone.
struct DeviceGauge: View {
    let device: WidgetDevice
    let now: Date

    var body: some View {
        Gauge(value: Double(device.percentage), in: 0...100) {
            Image(systemName: device.symbol)
        } currentValueLabel: {
            Image(systemName: device.isCharging ? "bolt.fill" : device.symbol)
        }
        .gaugeStyle(.accessoryCircularCapacity)
        .tint(device.tint)
        .opacity(device.isStale(at: now) ? 0.5 : 1)
        .accessibilityLabel(device.spoken(at: now))
    }
}

extension WidgetDevice {
    /// Green while charging, yellow in Low Power Mode, red when low — the
    /// battery's own colours, always beside a symbol or a number.
    var tint: Color {
        if isCharging { return .green }
        if lowPowerMode { return .yellow }
        if percentage <= 20 { return .red }
        return .primary
    }

    func spoken(at now: Date) -> String {
        var parts = [name, "\(percentage) percent"]
        if isCharging { parts.append("charging") }
        if lowPowerMode { parts.append("Low Power Mode") }
        if isStale(at: now) { parts.append("last seen \(date.formatted(.relative(presentation: .named)))") }
        return parts.joined(separator: ", ")
    }
}

#Preview(as: .systemMedium) {
    BatteriesWidget()
} timeline: {
    Entry(date: .now, devices: Provider.sample)
}
