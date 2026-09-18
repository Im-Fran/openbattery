import Charts
import SwiftUI

/// Everything the gas gauge will tell us, a tab per group of readings.
///
/// Every tab is built the same way — one headline reading, three numbers
/// beside it, and the history or breakdown underneath — so moving between
/// them never asks anyone to learn a new layout.
struct BatteryInfoView: View {
    static let windowID = "battery-info"

    @EnvironmentObject private var monitor: BatteryMonitor

    private var snapshot: BatterySnapshot { monitor.snapshot }

    var body: some View {
        TabView {
            ChargeTab(snapshot: snapshot, log: monitor.chargeLog)
                .tabItem { Label("Charge", systemImage: "battery.75percent") }
            PowerTab(snapshot: snapshot, load: monitor.load)
                .tabItem { Label("Power", systemImage: "bolt") }
            HealthTab(snapshot: snapshot, log: monitor.capacityLog)
                .tabItem { Label("Health", systemImage: "heart.text.square") }
            if let lifetime = snapshot.lifetime {
                LifetimeTab(lifetime: lifetime)
                    .tabItem { Label("Lifetime", systemImage: "clock.arrow.circlepath") }
            }
        }
        // Tall enough for the longest tab, so the window keeps still while
        // tabbing; wide enough for three stat tiles to sit side by side
        // without their titles wrapping.
        .frame(minWidth: 440, idealWidth: 500, minHeight: 420, idealHeight: 520)
        // On the window, not on each tab: switching tabs must not move the count.
        .onAppear { monitor.beginDetailUpdates() }
        .onDisappear { monitor.endDetailUpdates() }
    }
}

// MARK: - Tabs

private struct ChargeTab: View {
    let snapshot: BatterySnapshot
    let log: SampleLog

    var body: some View {
        HeroTab {
            HeroHeader(symbol: snapshot.isCharging ? "battery.100percent.bolt" : "battery.100percent",
                       variableValue: snapshot.isPresent ? Double(snapshot.percentage) / 100 : 0,
                       tint: snapshot.chargeTint,
                       value: snapshot.isPresent ? "\(snapshot.percentage)" : "—",
                       unit: "%",
                       status: snapshot.statusText,
                       meta: meta)
        } tiles: {
            StatTile("Time to full", Fmt.minutes(snapshot.timeToFull))
            StatTile("Time to empty", Fmt.minutes(snapshot.timeToEmpty))
            StatTile("Low Power Mode", snapshot.lowPowerMode ? "On" : "Off")
        } detail: {
            DetailSection("Last 12 hours", caption: "charge level") {
                BucketChart(buckets: log.bucketed(),
                            tint: .green,
                            domain: 0...100,
                            label: { "\($0)%" },
                            axis: .hour,
                            empty: "No readings yet. The chart fills in while OpenBattery is running.")
            }
        }
    }

    private var meta: String {
        let capacity: String
        if let current = snapshot.currentCapacityMAh, let full = snapshot.fullChargeCapacityMAh {
            capacity = "\(Fmt.integer(current)) of \(Fmt.mAh(full))"
        } else {
            capacity = Fmt.mAh(snapshot.currentCapacityMAh)
        }
        return "\(capacity)  ·  \(Fmt.celsius(snapshot.temperature))"
    }
}

private struct PowerTab: View {
    let snapshot: BatterySnapshot
    let load: [BatteryMonitor.LoadSample]

    var body: some View {
        HeroTab {
            HeroHeader(symbol: snapshot.isPluggedIn ? "powerplug.fill" : "battery.100percent",
                       variableValue: snapshot.isPluggedIn ? nil : Double(snapshot.percentage) / 100,
                       tint: snapshot.isPluggedIn ? .blue : snapshot.chargeTint,
                       value: Fmt.decimal(headlineWatts),
                       unit: "W",
                       status: status,
                       meta: meta)
        } tiles: {
            StatTile("Battery", Fmt.watts(snapshot.batteryWatts, signed: true))
            StatTile("Battery voltage", Fmt.volts(snapshot.volts))
            StatTile("Battery current", Fmt.amps(snapshot.amps))
        } detail: {
            DetailSection("Last 60 seconds", caption: "system load") {
                LoadChart(samples: load, isAvailable: snapshot.systemWatts != nil)
            }
        }
    }

    /// The number that answers "how much power is moving": what the adapter
    /// delivers when there is one, what the battery gives up when there is not.
    private var headlineWatts: Double? {
        snapshot.isPluggedIn ? snapshot.adapterWatts : snapshot.batteryWatts.map(abs)
    }

    private var status: String {
        guard snapshot.isPluggedIn else { return "Running on battery" }
        guard let watts = snapshot.batteryWatts else { return "On power adapter" }
        if watts > 0.05 { return "Charging from the adapter" }
        if watts < -0.05 { return "The adapter can't keep up · drawing from the battery" }
        return "Drawing from the adapter · battery idle"
    }

    private var meta: String {
        guard snapshot.isPluggedIn else {
            return "No adapter connected  ·  system \(Fmt.watts(snapshot.systemWatts))"
        }
        let parts = [
            snapshot.adapterRatedWatts.map { "\($0) W" },
            snapshot.adapterVolts.map { Fmt.volts($0) },
            snapshot.adapterAmps.map { Fmt.amps($0) },
        ].compactMap { $0 }
        let summary = parts.joined(separator: "  ·  ")
        guard let description = snapshot.adapterDescription, !description.isEmpty else {
            return summary.isEmpty ? "Power adapter" : summary
        }
        return summary.isEmpty ? description : "\(description)  ·  \(summary)"
    }

}

private struct HealthTab: View {
    let snapshot: BatterySnapshot
    let log: SampleLog

    var body: some View {
        HeroTab {
            // The tab's own symbol, not the Charge tab's battery: a part-filled
            // battery means "this much charge" everywhere else on the screen.
            HeroHeader(symbol: "heart.text.square",
                       tint: tint,
                       value: Fmt.decimal(snapshot.healthPercent),
                       unit: "%",
                       status: status,
                       meta: meta)
        } tiles: {
            StatTile("Cycles", cycles)
            StatTile("Age", snapshot.ageInDays.map { "\(Fmt.integer($0)) days" } ?? "—")
            StatTile("Nominal", Fmt.mAh(snapshot.nominalCapacityMAh))
        } detail: {
            DetailSection("Last 12 months", caption: "capacity retained") {
                BucketChart(buckets: retained,
                            tint: tint == .orange ? .orange : .green,
                            domain: 0...100,
                            label: { "\($0)%" },
                            axis: .month,
                            empty: "Capacity is written down once a day. The months fill in as they pass.")
            }
            InfoRows {
                InfoRow("Manufactured", Fmt.date(snapshot.manufactureDate))
                InfoRow("Serial number", snapshot.serialNumber ?? "—")
                InfoRow("Gauge", snapshot.deviceName ?? "—")
            }
        }
    }

    /// Apple's own threshold for a battery it still considers normal, and nil
    /// when there is no capacity to judge — an unknown battery must not be
    /// painted with a verdict the app does not have.
    private var isHealthy: Bool? { snapshot.healthPercent.map { $0 >= 80 } }

    private var tint: Color {
        guard let isHealthy else { return .secondary }
        return isHealthy ? .green : .orange
    }

    private var status: String {
        guard let isHealthy else { return "Capacity unknown" }
        if let count = snapshot.cycleCount, let design = snapshot.designCycleCount, count >= design {
            return "Past its rated cycle count"
        }
        return isHealthy ? "Normal · no service recommended"
                         : "Below 80% of design capacity · service recommended"
    }

    private var meta: String {
        let capacity: String
        if let full = snapshot.fullChargeCapacityMAh, let design = snapshot.designCapacityMAh {
            capacity = "\(Fmt.integer(full)) of \(Fmt.integer(design)) mAh design"
        } else {
            capacity = Fmt.mAh(snapshot.fullChargeCapacityMAh)
        }
        return "\(capacity)  ·  \(Fmt.integer(snapshot.cycleCount)) cycles"
    }

    private var cycles: String {
        guard let count = snapshot.cycleCount else { return "—" }
        guard let design = snapshot.designCycleCount else { return Fmt.integer(count) }
        return "\(Fmt.integer(count)) / \(Fmt.integer(design))"
    }

    /// The log stores mAh; a year of raw mAh all looks the same, so the chart
    /// shows what it means — how much of the design capacity is still there.
    private var retained: [SampleLog.Bucket] {
        guard let design = snapshot.designCapacityMAh, design > 0 else { return [] }
        return log.bucketed().map {
            SampleLog.Bucket(date: $0.date, value: $0.value.map { $0 * 100 / design })
        }
    }
}

private struct LifetimeTab: View {
    let lifetime: BatterySnapshot.Lifetime

    var body: some View {
        HeroTab {
            HeroHeader(symbol: "thermometer.medium",
                       tint: .orange,
                       value: Fmt.decimal(lifetime.averageTemperature),
                       unit: "°C avg",
                       status: status,
                       meta: meta)
        } tiles: {
            StatTile("Temperature range", temperatureRange)
            StatTile("Voltage range", voltageRange)
            StatTile("Operating time", operatingTime)
        } detail: {
            DetailSection("Extremes", caption: "peak charge / discharge current") {
                ExtremeBars(charge: lifetime.maximumChargeCurrentMA,
                            discharge: lifetime.maximumDischargeCurrentMA)
            }
        }
    }

    /// Lithium-ion is happiest well under 35 °C; this is the lifetime average,
    /// so a warm reading means warm for years, not warm this afternoon.
    private var status: String {
        guard let average = lifetime.averageTemperature else { return "No temperature record" }
        if average > 35 { return "Warmer than the ideal operating range" }
        if average < 15 { return "Cooler than the ideal operating range" }
        return "Within the ideal operating range"
    }

    private var meta: String {
        guard let raw = lifetime.operatingTimeRaw else {
            return "\(Fmt.integer(lifetime.temperatureSamples)) samples"
        }
        let days = BatteryDecoding.temperatureRecordDays(operatingTimeRawHours: raw)
        return "\(Fmt.days(days)) recorded  ·  \(Fmt.integer(lifetime.temperatureSamples)) samples"
    }

    private var temperatureRange: String {
        guard lifetime.minimumTemperature != nil || lifetime.maximumTemperature != nil else {
            return "—"
        }
        return "\(Fmt.decimal(lifetime.minimumTemperature)) … \(Fmt.celsius(lifetime.maximumTemperature))"
    }

    private var voltageRange: String {
        guard lifetime.minimumVoltage != nil || lifetime.maximumVoltage != nil else { return "—" }
        return "\(Fmt.decimal(lifetime.minimumVoltage, places: 2)) … \(Fmt.volts(lifetime.maximumVoltage))"
    }

    /// The raw counter's unit is an assumption, not a documented fact — see
    /// `BatteryDecoding.operatingTime`.
    private var operatingTime: String {
        guard let raw = lifetime.operatingTimeRaw else { return "—" }
        return "\(Fmt.integer(BatteryDecoding.operatingTime(rawHours: raw).hours)) h"
    }
}

// MARK: - Shared layout

/// The shape every tab takes: headline, three tiles, detail underneath.
private struct HeroTab<Tiles: View, Detail: View>: View {
    @ViewBuilder let header: HeroHeader
    @ViewBuilder let tiles: Tiles
    @ViewBuilder let detail: Detail

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                HStack(alignment: .top, spacing: 10) { tiles }
                detail
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
    }
}

/// The headline reading: a symbol that shows it, the number, and two lines
/// that say what it means and what it is made of.
private struct HeroHeader: View {
    let symbol: String
    var variableValue: Double? = nil
    let tint: Color
    let value: String
    let unit: String
    let status: String
    let meta: String

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: symbol, variableValue: variableValue)
                .font(.system(size: 54))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
                // A fixed box so the text starts in the same place on every
                // tab: a thermometer is far narrower than a battery.
                .frame(width: 76)
                // Everything it shows is written beside it.
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    // A display figure, not body copy: macOS has no Dynamic
                    // Type, and the point of the tab is to be readable from
                    // across the desk.
                    Text(value)
                        .font(.system(size: 42, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text(unit)
                        .font(.title3.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                // Not tinted: system green on a light window is about 1.8:1,
                // nowhere near the 4.5:1 this text needs. The symbol carries
                // the colour, the words carry the meaning.
                Text(status)
                    .font(.callout.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                Text(meta)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(value) \(unit)")
        .accessibilityValue("\(status). \(meta)")
    }
}

/// One boxed reading. Title small and quiet, value large and selectable.
private struct StatTile: View {
    let title: String
    let value: String

    init(_ title: String, _ value: String) {
        self.title = title
        self.value = value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel(title)
            Text(value)
                .font(.title3.weight(.medium))
                .monospacedDigit()
                .textSelection(.enabled)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.4)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(value)
    }
}

/// A titled block under the tiles: the chart, or whatever else the tab ends on.
private struct DetailSection<Content: View>: View {
    let title: String
    let caption: String
    @ViewBuilder let content: Content

    init(_ title: String, caption: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.caption = caption
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                SectionLabel(title).accessibilityAddTraits(.isHeader)
                Spacer()
                // Never .tertiary: at this size it measures under 2:1 against
                // the window in both appearances.
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            content
        }
    }
}

private struct SectionLabel: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .textCase(.uppercase)
            .tracking(0.4)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }
}

// MARK: - Charts

/// One bar per bucket, with the empty ones simply missing.
private struct BucketChart: View {
    let buckets: [SampleLog.Bucket]
    let tint: Color
    let domain: ClosedRange<Int>
    let label: (Int) -> String
    let axis: Calendar.Component
    let empty: String

    var body: some View {
        if buckets.contains(where: { $0.value != nil }) {
            chart
        } else {
            EmptyChart(text: empty)
        }
    }

    private var chart: some View {
        Chart(buckets) { bucket in
            if let value = bucket.value {
                BarMark(x: .value("When", bucket.date, unit: axis),
                        y: .value("Value", value))
                    .foregroundStyle(tint.gradient)
                    .cornerRadius(4)
                    .accessibilityLabel(Text(bucket.date, format: axisLabelFormat))
                    .accessibilityValue(label(value))
            }
        }
        .chartYScale(domain: domain)
        .chartYAxis {
            AxisMarks(values: [domain.lowerBound, (domain.lowerBound + domain.upperBound) / 2,
                               domain.upperBound]) { value in
                AxisGridLine()
                AxisValueLabel { if let number = value.as(Int.self) { Text(label(number)) } }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: axis, count: axis == .hour ? 3 : 2)) {
                AxisGridLine()
                AxisValueLabel(format: axisLabelFormat)
            }
        }
        .frame(height: 120)
    }

    /// The locale is pinned rather than inherited: an axis is the one place
    /// that would otherwise format itself in the system language while the
    /// rest of this English interface does not.
    private var axisLabelFormat: Date.FormatStyle {
        (axis == .hour ? Date.FormatStyle.dateTime.hour()
                       : Date.FormatStyle.dateTime.month(.abbreviated))
            .locale(Fmt.locale)
    }
}

/// System load over the last minute. A line, not bars: this one is a trend,
/// sampled every few seconds, not a reading per period.
private struct LoadChart: View {
    let samples: [BatteryMonitor.LoadSample]
    /// Not every Mac publishes a system load figure, and promising a sample
    /// that is never coming is worse than saying so.
    let isAvailable: Bool

    var body: some View {
        if samples.count > 1 {
            chart
        } else if isAvailable {
            EmptyChart(text: "Sampling system load…")
        } else {
            EmptyChart(text: "This Mac doesn't report what the system is drawing.")
        }
    }

    private var chart: some View {
        Chart(samples) { sample in
            AreaMark(x: .value("Time", sample.date), y: .value("Watts", sample.watts))
                .foregroundStyle(.blue.opacity(0.2))
                .interpolationMethod(.monotone)
                // Fill only: the line below plots the same samples, and
                // VoiceOver would otherwise read every watt reading twice.
                .accessibilityHidden(true)
            LineMark(x: .value("Time", sample.date), y: .value("Watts", sample.watts))
                .foregroundStyle(.blue)
                .interpolationMethod(.monotone)
                .accessibilityLabel(Text(sample.date, format: .dateTime.hour().minute().second()))
                .accessibilityValue(Fmt.watts(sample.watts))
        }
        .chartYScale(domain: 0...ceiling)
        .chartYAxis {
            AxisMarks(values: .automatic(desiredCount: 3)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let watts = value.as(Double.self) { Text(Fmt.watts(watts)) }
                }
            }
        }
        // Sixty seconds of wall clock times would be noise; the section title
        // says what the axis is.
        .chartXAxis(.hidden)
        .frame(height: 120)
    }

    /// Headroom above the peak so the line never touches the top edge.
    private var ceiling: Double {
        max(5, ((samples.map(\.watts).max() ?? 0) * 1.2).rounded(.up))
    }
}

private struct EmptyChart: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, minHeight: 120)
            .padding(.horizontal, 20)
    }
}

/// The two current records, drawn against whichever of them is larger.
private struct ExtremeBars: View {
    let charge: Int?
    let discharge: Int?

    private var peak: Double { Double(max(charge ?? 0, discharge ?? 0, 1)) }

    var body: some View {
        VStack(spacing: 8) {
            row("Max charge", charge, .green)
            row("Max discharge", discharge, .orange)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.4)))
    }

    private func row(_ title: String, _ milliamps: Int?, _ tint: Color) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.callout)
                .frame(width: 100, alignment: .leading)
            // Two capsules rather than a Gauge: this is one record measured
            // against the other, not progress towards a goal.
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(tint)
                        .frame(width: geometry.size.width * Double(milliamps ?? 0) / peak)
                }
            }
            .frame(height: 8)
            Text(Fmt.mA(milliamps))
                .font(.callout)
                .monospacedDigit()
                .frame(width: 76, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(Fmt.mA(milliamps))
    }
}

// MARK: - Building blocks

/// A short list of readings that are worth keeping but not worth a tile.
private struct InfoRows<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct InfoRow: View {
    let label: String
    let value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .textSelection(.enabled)
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
    }
}
