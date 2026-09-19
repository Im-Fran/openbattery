import XCTest

/// Fixtures are the real values read over `diagnostics_relay` from an iPhone 16
/// Pro (iPhone17,1) on iOS 27.2, charging at 84%.
final class DeviceBatteryTests: XCTestCase {

    /// A trimmed copy of the real dump: the keys this decoder reads, with the
    /// types the relay actually sends — booleans arrive as 0/1 integers.
    private func iPhoneRegistry(
        overrides: [String: Any] = [:],
        pack packOverrides: [String: Any] = [:]
    ) -> [String: Any] {
        var pack: [String: Any] = [
            "AppleRawCurrentCapacity": 2707,
            "AppleRawMaxCapacity": 3255,
            "FullChargeCapacity": 3255,
            "DesignCapacity": 3544,
            "NominalChargeCapacity": 3154,
            "CurrentCapacity": 84,
            "BatteryPower": 5222,
            "AvgTimeToEmpty": 130,
            "FullyCharged": 0,
        ]
        pack.merge(packOverrides) { _, new in new }

        var entry: [String: Any] = [
            "BatteryInstalled": 1,
            "IsCharging": 1,
            "ExternalConnected": 1,
            "FullyCharged": 0,
            "CurrentCapacity": 84,
            "CycleCount": 789,
            "Voltage": 4359,
            "Amperage": 1198,
            "InstantAmperage": 1193,
            "Serial": "F8YH7ZE04ZN0000RZ2",
            "TimeRemaining": 231,
            "AvgTimeToEmpty": 130,
            "BatteryData": pack,
            "AdapterDetails": [
                "Watts": 20, "AdapterVoltage": 5000, "Current": 3000,
                "Description": "usb host", "IsWireless": 0,
            ],
            "PowerTelemetryData": ["SystemLoad": 1631, "SystemPowerIn": 6853],
            "PowerDistribution": ["IPDInputPower": 6900],
        ]
        entry.merge(overrides) { _, new in new }
        return entry
    }

    func testPercentComesFromTheEntryAndMilliampHoursFromThePack() {
        let snapshot = DeviceBattery.decode(ioRegistry: iPhoneRegistry())
        // The trap this exists to catch: on an iPhone CurrentCapacity is a
        // percentage in one place and milliamp-hours in the other.
        XCTAssertEqual(snapshot.percentage, 84)
        XCTAssertEqual(snapshot.currentCapacityMAh, 2707)
        XCTAssertEqual(snapshot.fullChargeCapacityMAh, 3255)
        XCTAssertEqual(snapshot.designCapacityMAh, 3544)
        XCTAssertEqual(snapshot.nominalCapacityMAh, 3154)
    }

    func testCycleCountAndHealth() throws {
        let snapshot = DeviceBattery.decode(ioRegistry: iPhoneRegistry())
        XCTAssertEqual(snapshot.cycleCount, 789)
        XCTAssertEqual(try XCTUnwrap(snapshot.healthPercent), 91.84, accuracy: 0.01)
    }

    func testIntegersAreReadAsFlags() {
        let snapshot = DeviceBattery.decode(ioRegistry: iPhoneRegistry())
        XCTAssertTrue(snapshot.isPresent)
        XCTAssertTrue(snapshot.isCharging)
        XCTAssertTrue(snapshot.isPluggedIn)
        XCTAssertFalse(snapshot.isFullyCharged)
    }

    func testChargingUsesTimeRemainingAsTimeToFull() {
        let snapshot = DeviceBattery.decode(ioRegistry: iPhoneRegistry())
        // Charging, and the device only fills AvgTimeToEmpty: the remaining
        // estimate belongs to the direction the battery is moving.
        XCTAssertEqual(snapshot.timeToFull, 231)
        XCTAssertNil(snapshot.timeToEmpty)
    }

    func testPluggedInButNotChargingHasNoEstimateEitherWay() {
        // The stale AvgTimeToEmpty is still in the dump; a battery that is not
        // discharging has no time left to report.
        let snapshot = DeviceBattery.decode(ioRegistry: iPhoneRegistry(overrides: [
            "IsCharging": 0, "FullyCharged": 1,
        ]))
        XCTAssertNil(snapshot.timeToEmpty)
        XCTAssertNil(snapshot.timeToFull)
    }

    func testDischargingUsesTheAverageEstimate() {
        let snapshot = DeviceBattery.decode(ioRegistry: iPhoneRegistry(overrides: [
            "IsCharging": 0, "ExternalConnected": 0,
        ]))
        XCTAssertEqual(snapshot.timeToEmpty, 130)
        XCTAssertNil(snapshot.timeToFull)
    }

    func testUnitsAreConverted() throws {
        let snapshot = DeviceBattery.decode(ioRegistry: iPhoneRegistry())
        XCTAssertEqual(try XCTUnwrap(snapshot.volts), 4.359, accuracy: 0.0001)
        // InstantAmperage wins over Amperage, and milliamps become amps.
        XCTAssertEqual(try XCTUnwrap(snapshot.amps), 1.193, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(snapshot.batteryWatts), 5.222, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(snapshot.systemWatts), 1.631, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(snapshot.adapterWatts), 6.853, accuracy: 0.0001)
        XCTAssertEqual(snapshot.adapterRatedWatts, 20)
        XCTAssertEqual(snapshot.serialNumber, "F8YH7ZE04ZN0000RZ2")
    }

    func testAdapterIsIgnoredWhenNothingIsPluggedIn() {
        let snapshot = DeviceBattery.decode(ioRegistry: iPhoneRegistry(overrides: [
            "IsCharging": 0, "ExternalConnected": 0,
        ]))
        XCTAssertNil(snapshot.adapterRatedWatts)
        XCTAssertNil(snapshot.adapterDescription)
    }

    func testWirelessChargerGetsADescription() {
        let snapshot = DeviceBattery.decode(ioRegistry: iPhoneRegistry(overrides: [
            "AdapterDetails": ["Watts": 15, "IsWireless": 1],
        ]))
        XCTAssertEqual(snapshot.adapterDescription, "Wireless charger")
    }

    func testFallsBackToPowerDistributionForAdapterWatts() throws {
        let snapshot = DeviceBattery.decode(ioRegistry: iPhoneRegistry(overrides: [
            "PowerTelemetryData": ["SystemLoad": 1631],
        ]))
        XCTAssertEqual(try XCTUnwrap(snapshot.adapterWatts), 6.9, accuracy: 0.0001)
    }

    func testBatteryWattsFallBackToVoltsTimesAmps() throws {
        let snapshot = DeviceBattery.decode(ioRegistry: iPhoneRegistry(pack: ["BatteryPower": 0]))
        XCTAssertEqual(try XCTUnwrap(snapshot.batteryWatts), 4.359 * 1.193, accuracy: 0.0001)
    }

    func testAReplyWithoutChargeOrCapacityIsNotABatteryReply() {
        // The difference that matters: "no battery" is a claim about the phone,
        // "we could not read it" is a claim about us. An iPhone always has one.
        XCTAssertTrue(DeviceBattery.isBatteryReply(iPhoneRegistry()))
        XCTAssertFalse(DeviceBattery.isBatteryReply([:]))
        XCTAssertFalse(DeviceBattery.isBatteryReply(["BatteryData": ["Foo": 1]]))
        // A charge with no pack behind it, and a pack with no charge: neither is
        // enough to draw the window with.
        XCTAssertFalse(DeviceBattery.isBatteryReply(["CurrentCapacity": 84]))
        XCTAssertFalse(DeviceBattery.isBatteryReply(["BatteryData": ["DesignCapacity": 3544]]))
    }

    func testAnEmptyReplyDecodesToNothingRatherThanCrashing() {
        let snapshot = DeviceBattery.decode(ioRegistry: [:])
        XCTAssertFalse(snapshot.isPresent)
        XCTAssertEqual(snapshot.percentage, 0)
        XCTAssertNil(snapshot.cycleCount)
        XCTAssertNil(snapshot.healthPercent)
    }

    func testAPackWithoutTheInstalledFlagIsStillAPack() {
        var entry = iPhoneRegistry()
        entry["BatteryInstalled"] = nil
        XCTAssertTrue(DeviceBattery.decode(ioRegistry: entry).isPresent)
    }

    func testNoTemperatureOrLifetimeIsReportedForADevice() {
        let snapshot = DeviceBattery.decode(ioRegistry: iPhoneRegistry())
        // An iPhone publishes neither, and inventing them would be worse than
        // the views hiding what is missing.
        XCTAssertNil(snapshot.temperature)
        XCTAssertNil(snapshot.lifetime)
        XCTAssertNil(snapshot.manufactureDate)
    }
}
