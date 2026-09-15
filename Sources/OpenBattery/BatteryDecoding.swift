import Foundation

/// Pure decoding helpers for the raw IORegistry values.
///
/// This file is compiled into both the app and the test target, so it must not
/// import IOKit or touch any global state.
enum BatteryDecoding {

    // MARK: - Temperature

    /// The gas gauge mixes temperature scales inside the very same dictionary:
    /// `Temperature` is centi-Celsius (3059 = 30.59 C), `AverageTemperature` is
    /// deci-Celsius (243 = 24.3 C) and `MinimumTemperature`/`MaximumTemperature`
    /// are plain Celsius (45 = 45 C). Pick the scale by magnitude and reject
    /// anything a lithium pack could not physically report.
    static func normalizeCelsius(_ raw: Double) -> Double? {
        let celsius: Double
        switch abs(raw) {
        case 1000...: celsius = raw / 100
        case 100...: celsius = raw / 10
        default: celsius = raw
        }
        return (-40...100).contains(celsius) ? celsius : nil
    }

    // MARK: - Manufacture date

    /// `ManufactureDate` looks like a huge integer (57390245359923) but its
    /// little-endian bytes are ASCII: "310524" = DDMMYY = 2024-05-31.
    static func manufactureDate(fromPackedASCII raw: UInt64) -> Date? {
        let bytes = withUnsafeBytes(of: raw.littleEndian) { Array($0) }
        let digits = String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
        guard digits.count == 6, digits.allSatisfy(\.isNumber) else { return nil }
        let day = Int(digits.prefix(2))!
        let month = Int(digits.dropFirst(2).prefix(2))!
        let year = 2000 + Int(digits.suffix(2))!
        return date(year: year, month: month, day: day)
    }

    /// Fallback: `MfgData` carries a four digit YYWW code ("2419" = 2024, week 19).
    static func manufactureDate(fromMfgData data: Data) -> Date? {
        let ascii = data.map { (0x30...0x39).contains($0) ? Character(UnicodeScalar($0)) : " " }
        for run in String(ascii).split(separator: " ") where run.count == 4 {
            let year = 2000 + Int(run.prefix(2))!
            let week = Int(run.suffix(2))!
            guard week >= 1, week <= 53, year <= currentYear() + 1 else { continue }
            guard let jan1 = date(year: year, month: 1, day: 1) else { continue }
            return jan1.addingTimeInterval(Double(week - 1) * 7 * 86_400)
        }
        return nil
    }

    private static func date(year: Int, month: Int, day: Int) -> Date? {
        guard (1...12).contains(month), (1...31).contains(day),
              (2000...(currentYear() + 1)).contains(year) else { return nil }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = 12
        return Calendar(identifier: .gregorian).date(from: components)
    }

    private static func currentYear() -> Int {
        Calendar(identifier: .gregorian).component(.year, from: Date())
    }

    static func ageInDays(since manufactured: Date, now: Date = Date()) -> Int {
        max(0, Int(now.timeIntervalSince(manufactured) / 86_400))
    }

    // MARK: - Derived values

    static func healthPercent(fullCharge: Int?, design: Int?) -> Double? {
        guard let fullCharge, let design, design > 0, fullCharge > 0 else { return nil }
        return Double(fullCharge) / Double(design) * 100
    }

    /// 65535 is the gas gauge's "I don't know yet" sentinel for both ETAs.
    static func minutes(fromRawETA raw: Int?) -> Int? {
        guard let raw, raw > 0, raw != 65535 else { return nil }
        return raw
    }

    static func formatDuration(minutes: Int) -> String {
        String(format: "%d:%02d", minutes / 60, minutes % 60)
    }

    /// ponytail: `TotalOperatingTime` has no documented unit. The observed ratio
    /// on Apple Silicon is a constant 16 temperature samples per unit and the
    /// block only refreshes about hourly, so it cannot be calibrated at runtime.
    /// We read it as hours; the raw counter is shown next to it in the UI so a
    /// wrong assumption is visible rather than silent.
    static func operatingTime(rawHours raw: Int) -> (hours: Int, days: Double) {
        (raw, Double(raw) / 24)
    }

    /// The temperature log covers the same span as the operating-time counter,
    /// so derive it from the same base instead of guessing a sample interval.
    static func temperatureRecordDays(operatingTimeRawHours raw: Int) -> Double {
        Double(raw) / 24
    }
}
