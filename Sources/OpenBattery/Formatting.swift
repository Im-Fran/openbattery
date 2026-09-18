import Foundation
import SwiftUI

extension BatterySnapshot {
    /// The colours of the system battery icon. Never the only cue: the status
    /// text, the percentage and the Low Power label all say it in words too.
    var chargeTint: Color {
        if isCharging || (isPluggedIn && isFullyCharged) { return .green }
        if lowPowerMode { return .yellow }
        if percentage <= 20 && !isPluggedIn { return .red }
        return .secondary
    }
}

extension ShapeStyle where Self == Color {
    /// Quieter than a reading, louder than chrome: `.secondary` is about 4:1
    /// on a light window, under the 4.5:1 that text carrying or naming a
    /// number has to clear. Used for every label that qualifies a value.
    static var subdued: Color { Color.primary.opacity(0.7) }
}

/// Display formatting shared by the popover and the detail window.
enum Fmt {
    /// Shown wherever the gauge has nothing to report.
    static let unavailable = "—"

    /// What VoiceOver should say where the screen shows an em dash: on its
    /// own it is read as "em dash", or skipped, which sounds like a control
    /// that failed rather than a reading that does not exist.
    static func spoken(_ text: String) -> String {
        text.replacingOccurrences(of: unavailable, with: "Not available")
    }

    /// "1 day", "2 days". The interface is English only, so pluralising is a
    /// suffix rather than a rule engine.
    static func count(_ value: Int?, _ noun: String) -> String {
        guard let value else { return unavailable }
        return "\(integer(value)) \(noun)\(value == 1 ? "" : "s")"
    }

    static func watts(_ value: Double?, signed: Bool = false) -> String {
        guard let value else { return unavailable }
        let magnitude = String(format: "%.1f W", abs(value))
        guard signed, abs(value) >= 0.05 else { return magnitude }
        return (value > 0 ? "+" : "−") + magnitude
    }

    static func volts(_ value: Double?) -> String {
        value.map { String(format: "%.2f V", $0) } ?? unavailable
    }

    static func amps(_ value: Double?) -> String {
        value.map { String(format: "%.2f A", $0) } ?? unavailable
    }

    static func celsius(_ value: Double?) -> String {
        value.map { String(format: "%.1f °C", $0) } ?? unavailable
    }

    /// A bare number, for a headline reading whose unit is shown beside it or
    /// for the low end of a range that ends in one.
    static func decimal(_ value: Double?, places: Int = 1) -> String {
        guard let value else { return unavailable }
        return String(format: "%.\(places)f", value)
    }

    static func percent(_ value: Double?, decimals: Int = 1) -> String {
        value.map { String(format: "%.\(decimals)f%%", $0) } ?? unavailable
    }

    static func mAh(_ value: Int?) -> String {
        guard let value else { return unavailable }
        return "\(integer(value)) mAh"
    }

    static func mA(_ value: Int?) -> String {
        guard let value else { return unavailable }
        return "\(integer(value)) mA"
    }

    static func integer(_ value: Int?) -> String {
        guard let value else { return unavailable }
        return numberFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    static func days(_ value: Double?) -> String {
        count(value.map { Int($0.rounded()) }, "day")
    }

    static func date(_ value: Date?) -> String {
        guard let value else { return unavailable }
        // Named fields rather than a .medium style: the region still decides
        // the order, but an all-numeric date is ambiguous on any day of the
        // month that could also be a month, which is a third of them.
        return value.formatted(.dateTime.day().month(.abbreviated).year().locale(dateLocale))
    }

    static func minutes(_ value: Int?) -> String {
        guard let value else { return unavailable }
        return BatteryDecoding.formatDuration(minutes: value)
    }

    /// OpenBattery's interface is English, so its numbers are grouped the
    /// English way instead of following the system locale.
    static let numberLocale = Locale(identifier: "en_US")

    /// Dates and times keep the user's region, because region is a separate
    /// setting from language: a Mac set to a 24-hour clock has to read 15,
    /// not 3 PM, however the month beside it is spelled. English words,
    /// the user's own clock and date order. The chart axes read this too.
    static let dateLocale = englishLocale(basedOn: .autoupdatingCurrent)

    /// Only the language code is swapped. Replacing the whole language
    /// component drops the region and lands on a plain "en", which is how the
    /// 12-hour clock crept back in; this keeps the region, and with it the
    /// user's date order and their 24-Hour Time setting.
    static func englishLocale(basedOn locale: Locale) -> Locale {
        var components = Locale.Components(locale: locale)
        components.languageComponents.languageCode = .english
        return Locale(components: components)
    }

    private static let numberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = numberLocale
        return formatter
    }()
}
