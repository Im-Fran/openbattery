import Foundation
import IOKit

/// Reads the battery straight from the IORegistry. No root, no subprocesses.
///
/// Two levels on purpose: `quick` only touches the handful of keys the menu bar
/// shows, `detailed` also walks the much larger `AppleSmartBatteryPack` node.
/// The detailed read only runs while a window is actually open.
enum BatteryReader {

    enum Depth { case quick, detailed }

    static func read(_ depth: Depth = .quick) -> BatterySnapshot {
        var snapshot = BatterySnapshot()
        snapshot.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled

        let battery = IOServiceGetMatchingService(kIOMainPortDefault,
                                                  IOServiceMatching("AppleSmartBattery"))
        guard battery != IO_OBJECT_NULL else { return snapshot }
        defer { IOObjectRelease(battery) }

        snapshot.isPresent = bool(battery, "BatteryInstalled") ?? false
        snapshot.percentage = int(battery, "CurrentCapacity") ?? 0
        snapshot.isCharging = bool(battery, "IsCharging") ?? false
        snapshot.isPluggedIn = bool(battery, "ExternalConnected") ?? false
        snapshot.isFullyCharged = bool(battery, "FullyCharged") ?? false
        // `TimeRemaining` points in whichever direction the battery is moving,
        // so it may only stand in for the matching estimate.
        let remaining = BatteryDecoding.minutes(fromRawETA: int(battery, "TimeRemaining"))
        snapshot.timeToFull = BatteryDecoding.minutes(fromRawETA: int(battery, "AvgTimeToFull"))
            ?? (snapshot.isCharging ? remaining : nil)
        snapshot.timeToEmpty = BatteryDecoding.minutes(fromRawETA: int(battery, "AvgTimeToEmpty"))
            ?? (snapshot.isCharging ? nil : remaining)

        guard depth == .detailed else { return snapshot }

        snapshot.volts = int(battery, "Voltage").map { Double($0) / 1000 }
        snapshot.amps = int(battery, "Amperage").map { Double($0) / 1000 }
        snapshot.cycleCount = int(battery, "CycleCount")
        snapshot.serialNumber = string(battery, "Serial")
        snapshot.deviceName = string(battery, "DeviceName")

        if let telemetry = dictionary(battery, "PowerTelemetryData") {
            snapshot.systemWatts = milliwatts(telemetry["SystemLoad"])
            snapshot.adapterWatts = milliwatts(telemetry["SystemPowerIn"])
        }
        if snapshot.adapterWatts == nil, let distribution = dictionary(battery, "PowerDistribution") {
            snapshot.adapterWatts = milliwatts(distribution["IPDInputPower"])
        }
        if let adapter = dictionary(battery, "AdapterDetails"), snapshot.isPluggedIn {
            snapshot.adapterRatedWatts = number(adapter["Watts"])?.intValue
            snapshot.adapterVolts = number(adapter["AdapterVoltage"]).map { $0.doubleValue / 1000 }
            snapshot.adapterAmps = number(adapter["Current"]).map { $0.doubleValue / 1000 }
            snapshot.adapterDescription = adapter["Description"] as? String
        }

        readPack(into: &snapshot)

        // The pack is the better source for charge flow; fall back to V * A.
        if snapshot.batteryWatts == nil, let volts = snapshot.volts, let amps = snapshot.amps {
            snapshot.batteryWatts = volts * amps
        }
        return snapshot
    }

    // MARK: - AppleSmartBatteryPack

    private static func readPack(into snapshot: inout BatterySnapshot) {
        let pack = IOServiceGetMatchingService(kIOMainPortDefault,
                                               IOServiceMatching("AppleSmartBatteryPack"))
        guard pack != IO_OBJECT_NULL else { return }
        defer { IOObjectRelease(pack) }
        guard let data = dictionary(pack, "BatteryData") else { return }

        snapshot.currentCapacityMAh = number(data["AppleRawCurrentCapacity"])?.intValue
        snapshot.fullChargeCapacityMAh = number(data["FccComp1"])?.intValue
            ?? number(property(pack, "AppleRawMaxCapacity"))?.intValue
        snapshot.designCapacityMAh = number(data["DesignCapacity"])?.intValue
        snapshot.nominalCapacityMAh = number(data["NominalChargeCapacity"])?.intValue
        snapshot.cycleCount = number(data["CycleCount"])?.intValue ?? snapshot.cycleCount

        let rawTemperature = number(data["Temperature"]) ?? number(data["VirtualTemperature"])
        snapshot.temperature = rawTemperature.flatMap { BatteryDecoding.normalizeCelsius($0.doubleValue) }

        // BatteryPower is signed milliwatts: positive charging, negative draining.
        if let power = number(data["BatteryPower"])?.doubleValue, power != 0 {
            snapshot.batteryWatts = power / 1000
        }

        if let packed = number(data["ManufactureDate"])?.uint64Value {
            snapshot.manufactureDate = BatteryDecoding.manufactureDate(fromPackedASCII: packed)
        }
        if snapshot.manufactureDate == nil, let mfg = data["MfgData"] as? Data {
            snapshot.manufactureDate = BatteryDecoding.manufactureDate(fromMfgData: mfg)
        }

        guard let raw = data["LifetimeData"] as? [String: Any] else { return }
        var lifetime = BatterySnapshot.Lifetime()
        lifetime.averageTemperature = celsius(raw["AverageTemperature"])
        lifetime.minimumTemperature = celsius(raw["MinimumTemperature"])
        lifetime.maximumTemperature = celsius(raw["MaximumTemperature"])
        lifetime.maximumChargeCurrentMA = number(raw["MaximumChargeCurrent"])?.intValue
        // Discharge current is stored negative; the magnitude is what matters.
        lifetime.maximumDischargeCurrentMA = number(raw["MaximumDischargeCurrent"])
            .map { abs(Int($0.int64Value)) }
        lifetime.minimumVoltage = number(raw["MinimumPackVoltage"]).map { $0.doubleValue / 1000 }
        lifetime.maximumVoltage = number(raw["MaximumPackVoltage"]).map { $0.doubleValue / 1000 }
        lifetime.operatingTimeRaw = number(raw["TotalOperatingTime"])?.intValue
        lifetime.temperatureSamples = number(raw["TemperatureSamples"])?.intValue
        snapshot.lifetime = lifetime
    }

    // MARK: - IORegistry plumbing

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
    }

    private static func number(_ value: Any?) -> NSNumber? { value as? NSNumber }

    private static func int(_ entry: io_registry_entry_t, _ key: String) -> Int? {
        number(property(entry, key))?.intValue
    }

    private static func bool(_ entry: io_registry_entry_t, _ key: String) -> Bool? {
        property(entry, key) as? Bool
    }

    private static func string(_ entry: io_registry_entry_t, _ key: String) -> String? {
        property(entry, key) as? String
    }

    private static func dictionary(_ entry: io_registry_entry_t, _ key: String) -> [String: Any]? {
        property(entry, key) as? [String: Any]
    }

    private static func milliwatts(_ value: Any?) -> Double? {
        number(value).map { $0.doubleValue / 1000 }
    }

    private static func celsius(_ value: Any?) -> Double? {
        number(value).flatMap { BatteryDecoding.normalizeCelsius($0.doubleValue) }
    }
}
