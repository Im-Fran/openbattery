import SwiftUI

enum MenuBarDisplay: String, CaseIterable, Identifiable {
    case percentage
    case timeRemaining
    case iconOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .percentage: return "Percentage"
        case .timeRemaining: return "Time remaining"
        case .iconOnly: return "Icon only"
        }
    }
}

/// Icon plus optional text. Rendered on every battery change, so it stays cheap.
struct MenuBarLabel: View {
    let snapshot: BatterySnapshot
    @AppStorage("menuBarDisplay") private var display = MenuBarDisplay.percentage.rawValue

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbolName)
            if let text { Text(text) }
        }
    }

    private var text: String? {
        switch MenuBarDisplay(rawValue: display) ?? .percentage {
        case .percentage:
            return "\(snapshot.percentage)%"
        case .timeRemaining:
            guard let minutes = snapshot.remainingMinutes else { return "\(snapshot.percentage)%" }
            return BatteryDecoding.formatDuration(minutes: minutes)
        case .iconOnly:
            return nil
        }
    }

    /// SF Symbols that exist all the way back to macOS 11.
    private var symbolName: String {
        if snapshot.isCharging || (snapshot.isPluggedIn && snapshot.isFullyCharged) {
            return "battery.100.bolt"
        }
        switch snapshot.percentage {
        case 88...: return "battery.100"
        case 63...: return "battery.75"
        case 38...: return "battery.50"
        case 13...: return "battery.25"
        default: return "battery.0"
        }
    }
}
