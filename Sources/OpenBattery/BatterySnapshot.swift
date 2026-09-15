import Foundation

/// Everything OpenBattery knows about the battery at one point in time.
/// Values are already converted to human units (W, V, A, °C, mAh, minutes).
struct BatterySnapshot: Equatable {

    // MARK: Live state
    var percentage: Int = 0
    var isCharging = false
    var isPluggedIn = false
    var isFullyCharged = false
    var isPresent = false
    var lowPowerMode = false

    /// Minutes until full / empty, nil while the gauge is still estimating.
    var timeToFull: Int?
    var timeToEmpty: Int?

    // MARK: Power
    /// Battery flow in watts. Positive while charging, negative while discharging.
    var batteryWatts: Double?
    /// What the machine itself is consuming.
    var systemWatts: Double?
    /// What the power adapter is delivering.
    var adapterWatts: Double?
    var adapterRatedWatts: Int?
    var adapterVolts: Double?
    var adapterAmps: Double?
    var adapterDescription: String?

    var volts: Double?
    var amps: Double?
    var temperature: Double?

    // MARK: Capacity & health
    var currentCapacityMAh: Int?
    var fullChargeCapacityMAh: Int?
    var designCapacityMAh: Int?
    var nominalCapacityMAh: Int?
    var cycleCount: Int?
    var designCycleCount: Int?
    var serialNumber: String?
    var deviceName: String?
    var manufactureDate: Date?

    var lifetime: Lifetime?

    /// Raw gas-gauge lifetime log. See `BatteryDecoding.operatingTime` for the
    /// unit caveat on `operatingTimeRaw`.
    struct Lifetime: Equatable {
        var averageTemperature: Double?
        var minimumTemperature: Double?
        var maximumTemperature: Double?
        var maximumChargeCurrentMA: Int?
        var maximumDischargeCurrentMA: Int?
        var minimumVoltage: Double?
        var maximumVoltage: Double?
        var operatingTimeRaw: Int?
        var temperatureSamples: Int?
        var cycleCountLastQmax: Int?
    }

    // MARK: Derived

    var healthPercent: Double? {
        BatteryDecoding.healthPercent(fullCharge: fullChargeCapacityMAh, design: designCapacityMAh)
    }

    var ageInDays: Int? {
        manufactureDate.map { BatteryDecoding.ageInDays(since: $0) }
    }

    /// Minutes remaining in whatever direction the battery is moving.
    var remainingMinutes: Int? {
        isCharging ? timeToFull : timeToEmpty
    }

    /// Compact wording for the menu bar, where every character costs space.
    var shortStatusText: String {
        guard isPresent else { return "No battery" }
        if isCharging { return "Charging" }
        if isFullyCharged && isPluggedIn { return "Full" }
        return isPluggedIn ? "AC" : "Battery"
    }

    var statusText: String {
        guard isPresent else { return "No battery" }
        if isCharging, let minutes = timeToFull {
            return "Full in \(BatteryDecoding.formatDuration(minutes: minutes))"
        }
        if isCharging { return "Charging" }
        if isFullyCharged && isPluggedIn { return "Fully charged" }
        if isPluggedIn { return "Plugged in, not charging" }
        if let minutes = timeToEmpty {
            return "\(BatteryDecoding.formatDuration(minutes: minutes)) left"
        }
        return "On battery"
    }
}
