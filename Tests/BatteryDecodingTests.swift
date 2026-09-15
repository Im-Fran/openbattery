import XCTest

/// Fixtures are the real values read from a MacBook Air M2 running macOS 27.
final class BatteryDecodingTests: XCTestCase {

    func testManufactureDateIsPackedASCII() throws {
        // 57390245359923 == little-endian ASCII "310524" == 31 May 2024.
        let date = try XCTUnwrap(BatteryDecoding.manufactureDate(fromPackedASCII: 57_390_245_359_923))
        let components = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day],
                                                                        from: date)
        XCTAssertEqual(components.year, 2024)
        XCTAssertEqual(components.month, 5)
        XCTAssertEqual(components.day, 31)
    }

    func testManufactureDateRejectsNonsense() {
        XCTAssertNil(BatteryDecoding.manufactureDate(fromPackedASCII: 0))
        XCTAssertNil(BatteryDecoding.manufactureDate(fromPackedASCII: 1_789_443_028))
        // "994599" - day 99, month 45: valid ASCII, impossible date.
        let bogus = "994599".utf8.reversed().reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        XCTAssertNil(BatteryDecoding.manufactureDate(fromPackedASCII: bogus))
    }

    func testManufactureDateFallsBackToMfgDataWeekCode() throws {
        let mfgData = Data([0x00, 0x00, 0x00, 0x00, 0x0b, 0x00, 0x01, 0x00, 0x0d, 0x17, 0x00, 0x00,
                            0x04, 0x32, 0x34, 0x31, 0x39, 0x03, 0x30, 0x30, 0x41, 0x03, 0x43, 0x4f,
                            0x53, 0x00, 0x21, 0x00, 0x00, 0x00, 0x00, 0x00])
        let date = try XCTUnwrap(BatteryDecoding.manufactureDate(fromMfgData: mfgData))
        let components = Calendar(identifier: .gregorian).dateComponents([.year, .month], from: date)
        XCTAssertEqual(components.year, 2024)   // "2419" -> 2024, week 19
        XCTAssertEqual(components.month, 5)
    }

    func testTemperatureScalesAreDetectedByMagnitude() {
        XCTAssertEqual(BatteryDecoding.normalizeCelsius(3059)!, 30.59, accuracy: 0.001)  // centi
        XCTAssertEqual(BatteryDecoding.normalizeCelsius(243)!, 24.3, accuracy: 0.001)    // deci
        XCTAssertEqual(BatteryDecoding.normalizeCelsius(45)!, 45, accuracy: 0.001)       // plain
        XCTAssertEqual(BatteryDecoding.normalizeCelsius(12)!, 12, accuracy: 0.001)
    }

    func testImpossibleTemperaturesAreRejected() {
        XCTAssertNil(BatteryDecoding.normalizeCelsius(65535))
        XCTAssertNil(BatteryDecoding.normalizeCelsius(-99999))
    }

    func testHealthPercent() {
        XCTAssertEqual(BatteryDecoding.healthPercent(fullCharge: 5153, design: 5760)!,
                       89.46, accuracy: 0.01)
        XCTAssertNil(BatteryDecoding.healthPercent(fullCharge: 5153, design: 0))
        XCTAssertNil(BatteryDecoding.healthPercent(fullCharge: nil, design: 5760))
    }

    func testETASentinel() {
        XCTAssertEqual(BatteryDecoding.minutes(fromRawETA: 93), 93)
        XCTAssertNil(BatteryDecoding.minutes(fromRawETA: 65535))
        XCTAssertNil(BatteryDecoding.minutes(fromRawETA: 0))
        XCTAssertNil(BatteryDecoding.minutes(fromRawETA: nil))
    }

    func testDurationFormatting() {
        XCTAssertEqual(BatteryDecoding.formatDuration(minutes: 93), "1:33")
        XCTAssertEqual(BatteryDecoding.formatDuration(minutes: 5), "0:05")
        XCTAssertEqual(BatteryDecoding.formatDuration(minutes: 600), "10:00")
    }

    func testOperatingTimeConversion() {
        let time = BatteryDecoding.operatingTime(rawHours: 25668)
        XCTAssertEqual(time.hours, 25668)
        XCTAssertEqual(time.days, 1069.5, accuracy: 0.1)
        XCTAssertEqual(BatteryDecoding.temperatureRecordDays(operatingTimeRawHours: 25668),
                       time.days, accuracy: 0.001)
    }

    func testAgeInDays() {
        let manufactured = Date(timeIntervalSince1970: 0)
        let now = Date(timeIntervalSince1970: 86_400 * 10 + 3600)
        XCTAssertEqual(BatteryDecoding.ageInDays(since: manufactured, now: now), 10)
        XCTAssertEqual(BatteryDecoding.ageInDays(since: now, now: manufactured), 0)
    }
}
