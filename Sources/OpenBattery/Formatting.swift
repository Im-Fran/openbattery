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

/// Display formatting shared by the popover and the detail window.
enum Fmt {
    static func watts(_ value: Double?, signed: Bool = false) -> String {
        guard let value else { return "—" }
        let magnitude = String(format: "%.1f W", abs(value))
        guard signed, abs(value) >= 0.05 else { return magnitude }
        return (value > 0 ? "+" : "−") + magnitude
    }

    static func volts(_ value: Double?) -> String {
        value.map { String(format: "%.2f V", $0) } ?? "—"
    }

    static func amps(_ value: Double?) -> String {
        value.map { String(format: "%.2f A", $0) } ?? "—"
    }

    static func celsius(_ value: Double?) -> String {
        value.map { String(format: "%.1f °C", $0) } ?? "—"
    }

    static func percent(_ value: Double?, decimals: Int = 1) -> String {
        value.map { String(format: "%.\(decimals)f%%", $0) } ?? "—"
    }

    static func mAh(_ value: Int?) -> String {
        guard let value else { return "—" }
        return "\(integer(value)) mAh"
    }

    static func mA(_ value: Int?) -> String {
        guard let value else { return "—" }
        return "\(integer(value)) mA"
    }

    static func integer(_ value: Int?) -> String {
        guard let value else { return "—" }
        return numberFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    static func days(_ value: Double?) -> String {
        guard let value else { return "—" }
        return "\(integer(Int(value.rounded()))) days"
    }

    static func date(_ value: Date?) -> String {
        guard let value else { return "Unknown" }
        return dateFormatter.string(from: value)
    }

    static func minutes(_ value: Int?) -> String {
        guard let value else { return "—" }
        return BatteryDecoding.formatDuration(minutes: value)
    }

    /// OpenBattery's interface is English, so numbers and dates are formatted
    /// in English too instead of following the system locale.
    private static let locale = Locale(identifier: "en_US")

    private static let numberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = locale
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        formatter.locale = locale
        return formatter
    }()
}
