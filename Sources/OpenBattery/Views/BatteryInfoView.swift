import SwiftUI

/// Everything the gas gauge will tell us, a tab per group of readings.
struct BatteryInfoView: View {
    static let windowID = "battery-info"

    @EnvironmentObject private var monitor: BatteryMonitor

    private var snapshot: BatterySnapshot { monitor.snapshot }

    var body: some View {
        TabView {
            ChargeTab(snapshot: snapshot)
                .tabItem { Label("Charge", systemImage: "battery.75percent") }
            PowerTab(snapshot: snapshot)
                .tabItem { Label("Power", systemImage: "bolt") }
            HealthTab(snapshot: snapshot)
                .tabItem { Label("Health", systemImage: "heart.text.square") }
            if let lifetime = snapshot.lifetime {
                LifetimeTab(lifetime: lifetime)
                    .tabItem { Label("Lifetime", systemImage: "clock.arrow.circlepath") }
            }
        }
        // Tall enough for the longest tab, so the window keeps still while tabbing.
        .frame(minWidth: 380, idealWidth: 420, minHeight: 340, idealHeight: 400)
        // On the window, not on each tab: switching tabs must not move the count.
        .onAppear { monitor.beginDetailUpdates() }
        .onDisappear { monitor.endDetailUpdates() }
    }
}

// MARK: - Tabs

private struct ChargeTab: View {
    let snapshot: BatterySnapshot

    var body: some View {
        InfoRows {
            InfoRow("Current charge", "\(snapshot.percentage)%  ·  \(Fmt.mAh(snapshot.currentCapacityMAh))")
            InfoRow("Status", snapshot.statusText)
            InfoRow("Time to full", Fmt.minutes(snapshot.timeToFull))
            InfoRow("Time to empty", Fmt.minutes(snapshot.timeToEmpty))
            InfoRow("Low Power Mode", snapshot.lowPowerMode ? "On" : "Off")
            InfoRow("Temperature", Fmt.celsius(snapshot.temperature))
        }
    }
}

private struct PowerTab: View {
    let snapshot: BatterySnapshot

    var body: some View {
        InfoRows {
            InfoRow("Battery", Fmt.watts(snapshot.batteryWatts, signed: true))
            InfoRow("System load", Fmt.watts(snapshot.systemWatts))
            InfoRow("Adapter input", Fmt.watts(snapshot.adapterWatts))
            InfoRow("Battery voltage", Fmt.volts(snapshot.volts))
            InfoRow("Battery current", Fmt.amps(snapshot.amps))
            if snapshot.isPluggedIn {
                InfoRow("Adapter", adapterSummary)
            }
        }
    }

    private var adapterSummary: String {
        let parts = [
            snapshot.adapterRatedWatts.map { "\($0) W" },
            snapshot.adapterVolts.map { Fmt.volts($0) },
            snapshot.adapterAmps.map { Fmt.amps($0) },
        ].compactMap { $0 }
        let summary = parts.joined(separator: "  ·  ")
        guard let description = snapshot.adapterDescription, !description.isEmpty else {
            return summary.isEmpty ? "—" : summary
        }
        return summary.isEmpty ? description : "\(description)  ·  \(summary)"
    }
}

private struct HealthTab: View {
    let snapshot: BatterySnapshot

    var body: some View {
        InfoRows {
            InfoRow("Full charge capacity", Fmt.mAh(snapshot.fullChargeCapacityMAh))
            InfoRow("Design capacity", Fmt.mAh(snapshot.designCapacityMAh))
            InfoRow("Nominal capacity", Fmt.mAh(snapshot.nominalCapacityMAh))
            InfoRow("Health", Fmt.percent(snapshot.healthPercent))
            InfoRow("Cycle count", cycleSummary)
            InfoRow("Manufactured", Fmt.date(snapshot.manufactureDate))
            InfoRow("Age", snapshot.ageInDays.map { "\(Fmt.integer($0)) days" } ?? "—")
            InfoRow("Serial number", snapshot.serialNumber ?? "—")
            InfoRow("Gauge", snapshot.deviceName ?? "—")
        }
    }

    private var cycleSummary: String {
        guard let count = snapshot.cycleCount else { return "—" }
        guard let design = snapshot.designCycleCount else { return Fmt.integer(count) }
        return "\(Fmt.integer(count)) of \(Fmt.integer(design))"
    }
}

private struct LifetimeTab: View {
    let lifetime: BatterySnapshot.Lifetime

    var body: some View {
        InfoRows {
            InfoRow("Average temperature", Fmt.celsius(lifetime.averageTemperature))
            InfoRow("Temperature range", temperatureRange)
            InfoRow("Max charge rate", Fmt.mA(lifetime.maximumChargeCurrentMA))
            InfoRow("Max discharge rate", Fmt.mA(lifetime.maximumDischargeCurrentMA))
            InfoRow("Voltage range", voltageRange)
            InfoRow("Operating time", operatingTime)
            InfoRow("Temperature record", temperatureRecord)
        }
    }

    private var temperatureRange: String {
        guard lifetime.minimumTemperature != nil || lifetime.maximumTemperature != nil else {
            return "—"
        }
        return "\(Fmt.celsius(lifetime.minimumTemperature)) … \(Fmt.celsius(lifetime.maximumTemperature))"
    }

    private var voltageRange: String {
        guard lifetime.minimumVoltage != nil || lifetime.maximumVoltage != nil else { return "—" }
        return "\(Fmt.volts(lifetime.minimumVoltage)) … \(Fmt.volts(lifetime.maximumVoltage))"
    }

    /// The raw counter is shown alongside the conversion because its unit is an
    /// assumption, not a documented fact.
    private var operatingTime: String {
        guard let raw = lifetime.operatingTimeRaw else { return "—" }
        let time = BatteryDecoding.operatingTime(rawHours: raw)
        return "\(Fmt.integer(time.hours)) h  ·  \(Fmt.days(time.days))"
    }

    private var temperatureRecord: String {
        guard let raw = lifetime.operatingTimeRaw else { return "—" }
        let days = BatteryDecoding.temperatureRecordDays(operatingTimeRawHours: raw)
        let samples = Fmt.integer(lifetime.temperatureSamples)
        return "\(Fmt.days(days))  ·  \(samples) samples"
    }
}

// MARK: - Building blocks

/// One tab's readings: scrolls so a long value can never clip the last row.
private struct InfoRows<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
        }
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
