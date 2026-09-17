import SwiftUI

/// Icon plus whichever fields the user picked. Rendered on every battery
/// change, so it stays cheap.
struct MenuBarLabel: View {
    let snapshot: BatterySnapshot

    @AppStorage(MenuBarConfig.itemsKey) private var rawItems = MenuBarConfig.default.rawItems
    @AppStorage(MenuBarConfig.iconKey) private var showsIcon = MenuBarConfig.default.showsIcon

    private var config: MenuBarConfig {
        MenuBarConfig(showsIcon: showsIcon, rawItems: rawItems)
    }

    var body: some View {
        HStack(spacing: 3) {
            if config.showsIcon(for: snapshot) {
                Image(systemName: symbolName)
            }
            if let text = config.text(for: snapshot) {
                Text(text)
            }
        }
        // One spoken summary instead of a symbol name; any other picked
        // fields follow as the value.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityValue(MenuBarConfig(showsIcon: false,
                                          items: config.items.filter { $0 != .percentage })
            .text(for: snapshot) ?? "")
    }

    private var accessibilityText: String {
        guard snapshot.isPresent else { return "No battery" }
        return "Battery \(snapshot.percentage)%" + (snapshot.isCharging ? ", charging" : "")
    }

    private var symbolName: String {
        // No battery means mains power.
        guard snapshot.isPresent else { return "powerplug" }
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
