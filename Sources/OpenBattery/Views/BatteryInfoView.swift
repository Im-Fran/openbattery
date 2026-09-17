import SwiftUI

/// Everything the gas gauge will tell us, grouped for reading.
struct BatteryInfoView: View {
    static let windowID = "battery-info"

    @EnvironmentObject private var monitor: BatteryMonitor

    private var snapshot: BatterySnapshot { monitor.snapshot }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                section("Charge") {
                    row("Current charge", "\(snapshot.percentage)%  ·  \(Fmt.mAh(snapshot.currentCapacityMAh))")
                    row("Status", snapshot.statusText)
                    row("Time to full", Fmt.minutes(snapshot.timeToFull))
                    row("Time to empty", Fmt.minutes(snapshot.timeToEmpty))
                    row("Low Power Mode", snapshot.lowPowerMode ? "On" : "Off")
                    row("Temperature", Fmt.celsius(snapshot.temperature))
                }

                section("Power") {
                    row("Battery", Fmt.watts(snapshot.batteryWatts, signed: true))
                    row("System load", Fmt.watts(snapshot.systemWatts))
                    row("Adapter input", Fmt.watts(snapshot.adapterWatts))
                    row("Battery voltage", Fmt.volts(snapshot.volts))
                    row("Battery current", Fmt.amps(snapshot.amps))
                    if snapshot.isPluggedIn {
                        row("Adapter", adapterSummary)
                    }
                }

                section("Health") {
                    row("Full charge capacity", Fmt.mAh(snapshot.fullChargeCapacityMAh))
                    row("Design capacity", Fmt.mAh(snapshot.designCapacityMAh))
                    row("Nominal capacity", Fmt.mAh(snapshot.nominalCapacityMAh))
                    row("Health", Fmt.percent(snapshot.healthPercent))
                    row("Cycle count", cycleSummary)
                    row("Manufactured", Fmt.date(snapshot.manufactureDate))
                    row("Age", snapshot.ageInDays.map { "\(Fmt.integer($0)) days" } ?? "—")
                    row("Serial number", snapshot.serialNumber ?? "—")
                    row("Gauge", snapshot.deviceName ?? "—")
                }

                if let lifetime = snapshot.lifetime {
                    section("Lifetime log") {
                        row("Average temperature", Fmt.celsius(lifetime.averageTemperature))
                        row("Temperature range", temperatureRange(lifetime))
                        row("Max charge rate", Fmt.mA(lifetime.maximumChargeCurrentMA))
                        row("Max discharge rate", Fmt.mA(lifetime.maximumDischargeCurrentMA))
                        row("Voltage range", voltageRange(lifetime))
                        row("Operating time", operatingTime(lifetime))
                        row("Temperature record", temperatureRecord(lifetime))
                    }
                }
            }
            .padding(20)
        }
        .frame(width: 420, height: 560)
        .onAppear { monitor.beginDetailUpdates() }
        .onDisappear { monitor.endDetailUpdates() }
    }

    // MARK: - Building blocks

    private func section<Content: View>(_ title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
            VStack(alignment: .leading, spacing: 4) { content() }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
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

    // MARK: - Composed values

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

    private var cycleSummary: String {
        guard let count = snapshot.cycleCount else { return "—" }
        guard let design = snapshot.designCycleCount else { return Fmt.integer(count) }
        return "\(Fmt.integer(count)) of \(Fmt.integer(design))"
    }

    private func temperatureRange(_ lifetime: BatterySnapshot.Lifetime) -> String {
        guard lifetime.minimumTemperature != nil || lifetime.maximumTemperature != nil else {
            return "—"
        }
        return "\(Fmt.celsius(lifetime.minimumTemperature)) … \(Fmt.celsius(lifetime.maximumTemperature))"
    }

    private func voltageRange(_ lifetime: BatterySnapshot.Lifetime) -> String {
        guard lifetime.minimumVoltage != nil || lifetime.maximumVoltage != nil else { return "—" }
        return "\(Fmt.volts(lifetime.minimumVoltage)) … \(Fmt.volts(lifetime.maximumVoltage))"
    }

    /// The raw counter is shown alongside the conversion because its unit is an
    /// assumption, not a documented fact.
    private func operatingTime(_ lifetime: BatterySnapshot.Lifetime) -> String {
        guard let raw = lifetime.operatingTimeRaw else { return "—" }
        let time = BatteryDecoding.operatingTime(rawHours: raw)
        return "\(Fmt.integer(time.hours)) h  ·  \(Fmt.days(time.days))"
    }

    private func temperatureRecord(_ lifetime: BatterySnapshot.Lifetime) -> String {
        guard let raw = lifetime.operatingTimeRaw else { return "—" }
        let days = BatteryDecoding.temperatureRecordDays(operatingTimeRawHours: raw)
        let samples = Fmt.integer(lifetime.temperatureSamples)
        return "\(Fmt.days(days))  ·  \(samples) samples"
    }
}
