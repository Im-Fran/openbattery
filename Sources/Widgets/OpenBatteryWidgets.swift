import AppIntents
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
        AppIntentConfiguration(kind: "Batteries", intent: ChooseDevices.self, provider: Provider()) { entry in
            BatteriesView(entry: entry)
                .containerBackground(.background, for: .widget)
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
struct Provider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> Entry {
        Entry(date: .now, devices: Self.sample)
    }

    func snapshot(for configuration: ChooseDevices, in context: Context) async -> Entry {
        let devices = Self.devices(for: configuration)
        // The gallery shows the snapshot before anything was ever written.
        return Entry(date: .now, devices: devices.isEmpty && context.isPreview ? Self.sample : devices)
    }

    func timeline(for configuration: ChooseDevices, in context: Context) async -> Timeline<Entry> {
        let now = Date.now
        return Timeline(entries: [Entry(date: now, devices: Self.devices(for: configuration))],
                        policy: .after(now.addingTimeInterval(15 * 60)))
    }

    private static func devices(for configuration: ChooseDevices) -> [WidgetDevice] {
        WidgetDevice.picked(configuration.devices?.map(\.id), from: WidgetDevice.read())
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

// MARK: - Choosing devices

/// Which devices a widget shows, set from Edit Widget. The system's own
/// Batteries widget always shows everything nearby; this one can be told to
/// keep to, say, the two Macs.
struct ChooseDevices: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Choose Devices"
    static let description = IntentDescription("Pick the devices to show. Leave it empty to show them all.")

    @Parameter(title: "Devices")
    var devices: [DeviceEntity]?
}

struct DeviceEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Device"
    static let defaultQuery = DeviceQuery()

    let id: String
    let name: String
    let symbol: String

    init(_ device: WidgetDevice) {
        id = device.id
        name = device.name
        symbol = device.symbol
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", image: .init(systemName: symbol))
    }
}

/// Offers what the apps last wrote, so a device appears here once any app
/// on the account has seen it.
struct DeviceQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [DeviceEntity] {
        WidgetDevice.read().filter { identifiers.contains($0.id) }.map(DeviceEntity.init)
    }

    func suggestedEntities() async throws -> [DeviceEntity] {
        WidgetDevice.read().map(DeviceEntity.init)
    }
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

    /// The device in `index`, or nil for an empty slot: like the system's
    /// Batteries widget, every layout keeps its slots and shows the empty
    /// ones as bare rings or rows.
    private func slot(_ index: Int) -> WidgetDevice? {
        index < entry.devices.count ? entry.devices[index] : nil
    }

    /// One device: its ring and a large percentage. More: four rings.
    @ViewBuilder private var small: some View {
        if entry.devices.count == 1 {
            let device = entry.devices[0]
            VStack(alignment: .leading, spacing: 0) {
                DeviceRing(device: device, now: entry.date)
                    .frame(width: 64, height: 64)
                Spacer(minLength: 0)
                Text("\(device.percentage)%")
                    .font(.system(size: 44))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        } else {
            Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                ForEach(0..<2, id: \.self) { row in
                    GridRow {
                        DeviceRing(device: slot(row * 2), now: entry.date)
                        DeviceRing(device: slot(row * 2 + 1), now: entry.date)
                    }
                }
            }
        }
    }

    private var medium: some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(0..<4, id: \.self) { index in
                VStack(spacing: 8) {
                    DeviceRing(device: slot(index), now: entry.date)
                    Text(slot(index).map { "\($0.percentage)%" } ?? " ")
                        .font(.title3)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var large: some View {
        VStack(spacing: 0) {
            ForEach(0..<6, id: \.self) { index in
                if index > 0 { Divider().padding(.leading, 40) }
                Group {
                    if let device = slot(index) {
                        HStack(spacing: 12) {
                            Image(systemName: device.symbol)
                                .font(.title3)
                                .frame(width: 28)
                            Text(device.name).lineLimit(1)
                            Spacer(minLength: 4)
                            Text("\(device.percentage)%")
                                .font(.subheadline)
                                .monospacedDigit()
                            Image(systemName: device.batterySymbol)
                                .foregroundStyle(device.tint)
                        }
                        .opacity(device.isStale(at: entry.date) ? 0.5 : 1)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(device.spoken(at: entry.date))
                    } else {
                        Color.clear
                    }
                }
                .frame(maxHeight: .infinity)
            }
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

/// The system Batteries widget's ring: a thick track filled to the charge,
/// the device's symbol inside and a bolt cut into the top while it charges,
/// so charging is never colour alone. Nil draws the empty slot's bare track.
/// Everything scales with the ring, so one shape serves every widget size.
struct DeviceRing: View {
    let device: WidgetDevice?
    let now: Date

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            let line = side * 0.1
            ZStack {
                Circle().stroke(.quaternary, lineWidth: line)
                if let device {
                    Circle()
                        .trim(from: 0, to: Double(device.percentage) / 100)
                        .stroke(device.tint, style: StrokeStyle(lineWidth: line, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: device.symbol)
                        .resizable()
                        .scaledToFit()
                        .frame(width: side * 0.4, height: side * 0.4)
                    if device.isCharging {
                        Image(systemName: "bolt.fill")
                            .resizable()
                            .scaledToFit()
                            .frame(width: side * 0.14, height: side * 0.14)
                            .padding(side * 0.04)
                            .background(Circle().fill(.background))
                            .offset(y: -side / 2 + line / 2)
                    }
                }
            }
            .padding(line / 2)
            .frame(width: side, height: side)
            // GeometryReader puts its content top-leading; centre the ring.
            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }
        .aspectRatio(1, contentMode: .fit)
        .opacity(device.map { $0.isStale(at: now) ? 0.5 : 1 } ?? 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(device?.spoken(at: now) ?? "")
        .accessibilityHidden(device == nil)
    }
}

/// The Lock Screen's ring, which follows the system's tinting there.
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
    /// The system widget's colours: green, yellow in Low Power Mode, red when
    /// low and not charging — always beside a symbol or a number.
    var tint: Color {
        if lowPowerMode { return .yellow }
        if percentage <= 20 && !isCharging { return .red }
        return .green
    }

    /// The status bar's battery, filled to the nearest quarter.
    var batterySymbol: String {
        if isCharging { return "battery.100percent.bolt" }
        switch percentage {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
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
