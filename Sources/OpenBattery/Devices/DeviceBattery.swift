import Foundation

/// Who a device is, separately from what its battery is doing.
struct DeviceIdentity: Equatable, Identifiable {
    let udid: String
    /// What the device calls itself, e.g. "Fran's iPhone".
    var name: String?
    /// `iPhone17,1` and friends.
    var model: String?
    var systemVersion: String?
    var isNetwork: Bool

    var id: String { udid }

    /// Something to show before lockdown has answered.
    var displayName: String { name ?? model ?? udid }
}

/// Turns an Apple device's `AppleSmartBattery` IORegistry dictionary into the
/// same snapshot the Mac's own battery produces, so every view already knows how
/// to draw it.
///
/// This file is compiled into the app and the test target: no I/O, no NIO.
enum DeviceBattery {

    /// Whether a reply is worth decoding at all. A dictionary carrying neither a
    /// charge nor a capacity is one we failed to read — an iOS key renamed, or
    /// the partial payload a device sends while it boots — and an iPhone always
    /// has a battery. Saying "No Battery" there would be a confident wrong
    /// diagnosis; the caller turns this into an error the window can retry.
    static func isBatteryReply(_ entry: [String: Any]) -> Bool {
        let pack = entry["BatteryData"] as? [String: Any] ?? [:]
        let hasCharge = number(entry["CurrentCapacity"]) != nil
            || number(pack["CurrentCapacity"]) != nil
        let hasPack = number(pack["DesignCapacity"]) != nil
            || number(pack["AppleRawMaxCapacity"]) != nil
            || flag(entry["BatteryInstalled"]) != nil
        return hasCharge && hasPack
    }

    static func decode(ioRegistry entry: [String: Any]) -> BatterySnapshot {
        var snapshot = BatterySnapshot()
        let pack = entry["BatteryData"] as? [String: Any] ?? [:]

        // The relay serialises IORegistry booleans as 0/1, not as booleans.
        // A pack that reports a design capacity is a pack that exists; that is a
        // better fallback than assuming either way.
        snapshot.isPresent = flag(entry["BatteryInstalled"])
            ?? (number(pack["DesignCapacity"]) != nil)
        snapshot.isCharging = flag(entry["IsCharging"]) ?? false
        snapshot.isPluggedIn = flag(entry["ExternalConnected"]) ?? false
        snapshot.isFullyCharged = flag(entry["FullyCharged"]) ?? false
        // Unlike the Mac, an iPhone reports percent here and milliamp-hours in
        // the pack, so nothing derives the percentage from capacities.
        snapshot.percentage = number(entry["CurrentCapacity"])?.intValue
            ?? number(pack["CurrentCapacity"])?.intValue ?? 0

        // Only the estimate that matches the direction the battery is moving.
        // Unlike a Mac's gauge, which parks the unused estimate on its 65535
        // sentinel, an iPhone leaves a stale AvgTimeToEmpty sitting there while
        // it charges — reading it would show "2:10 left" on a charging phone.
        let remaining = BatteryDecoding.minutes(fromRawETA: number(entry["TimeRemaining"])?.intValue)
        if snapshot.isCharging {
            snapshot.timeToFull = BatteryDecoding.minutes(
                fromRawETA: number(entry["AvgTimeToFull"] ?? pack["AvgTimeToFull"])?.intValue)
                ?? remaining
        } else if !snapshot.isPluggedIn {
            snapshot.timeToEmpty = BatteryDecoding.minutes(
                fromRawETA: number(entry["AvgTimeToEmpty"] ?? pack["AvgTimeToEmpty"])?.intValue)
                ?? remaining
        }

        snapshot.volts = number(entry["Voltage"]).map { $0.doubleValue / 1000 }
        snapshot.amps = number(entry["InstantAmperage"] ?? entry["Amperage"])
            .map { $0.doubleValue / 1000 }
        snapshot.serialNumber = entry["Serial"] as? String

        snapshot.currentCapacityMAh = number(pack["AppleRawCurrentCapacity"])?.intValue
        // AppleRawMaxCapacity plays the part FccComp1 plays on a Mac, so health
        // means the same thing on both.
        snapshot.fullChargeCapacityMAh = number(pack["AppleRawMaxCapacity"]
            ?? pack["FullChargeCapacity"])?.intValue
        snapshot.designCapacityMAh = number(pack["DesignCapacity"])?.intValue
        snapshot.nominalCapacityMAh = number(pack["NominalChargeCapacity"])?.intValue
        snapshot.cycleCount = number(entry["CycleCount"] ?? pack["CycleCount"])?.intValue

        // Signed milliwatts, same as the Mac's pack.
        if let power = number(pack["BatteryPower"])?.doubleValue, power != 0 {
            snapshot.batteryWatts = power / 1000
        }
        if let telemetry = entry["PowerTelemetryData"] as? [String: Any] {
            snapshot.systemWatts = milliwatts(telemetry["SystemLoad"])
            snapshot.adapterWatts = milliwatts(telemetry["SystemPowerIn"])
        }
        if snapshot.adapterWatts == nil,
           let distribution = entry["PowerDistribution"] as? [String: Any] {
            snapshot.adapterWatts = milliwatts(distribution["IPDInputPower"])
        }
        if let adapter = entry["AdapterDetails"] as? [String: Any], snapshot.isPluggedIn {
            snapshot.adapterRatedWatts = number(adapter["Watts"])?.intValue
            snapshot.adapterVolts = number(adapter["AdapterVoltage"]).map { $0.doubleValue / 1000 }
            snapshot.adapterAmps = number(adapter["Current"]).map { $0.doubleValue / 1000 }
            snapshot.adapterDescription = adapter["Description"] as? String
                ?? (flag(adapter["IsWireless"]) == true ? "Wireless charger" : nil)
        }
        if snapshot.batteryWatts == nil, let volts = snapshot.volts, let amps = snapshot.amps {
            snapshot.batteryWatts = volts * amps
        }

        // Deliberately absent: temperature, which an iPhone does not publish
        // (the only temperature fields in the dump are zeroes in a boot-time
        // payload), a manufacture date, and the gauge's lifetime log. The views
        // already hide what a snapshot does not have.
        return snapshot
    }

    // MARK: - Reading loosely typed plist values

    private static func number(_ value: Any?) -> NSNumber? { value as? NSNumber }

    private static func flag(_ value: Any?) -> Bool? {
        if let bool = value as? Bool { return bool }
        return number(value).map { $0.intValue != 0 }
    }

    private static func milliwatts(_ value: Any?) -> Double? {
        number(value).map { $0.doubleValue / 1000 }
    }
}
