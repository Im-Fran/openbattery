import Foundation

/// A field that can be shown in the menu bar.
///
/// `requiresDetailedRead` matters: the cheap read only fills charge and status,
/// so picking any of the other fields makes `BatteryMonitor` keep the detailed
/// read running. That is the user's call, and it costs a timer.
enum MenuBarItem: String, CaseIterable, Identifiable {
    case percentage
    case timeRemaining
    case chargingStatus
    case batteryWatts
    case adapterWatts
    case systemWatts
    case capacity
    case temperature

    var id: String { rawValue }

    var title: String {
        switch self {
        case .percentage: return "Percentage"
        case .timeRemaining: return "Time remaining"
        case .chargingStatus: return "Charging status"
        case .batteryWatts: return "Battery watts"
        case .adapterWatts: return "Adapter watts"
        case .systemWatts: return "System watts"
        case .capacity: return "Charge in mAh"
        case .temperature: return "Temperature"
        }
    }

    var requiresDetailedRead: Bool {
        switch self {
        case .percentage, .timeRemaining, .chargingStatus: return false
        default: return true
        }
    }

    /// The text to show, or nil when the value is not available right now —
    /// an unplugged Mac has no adapter watts, and a dash in the menu bar is
    /// worse than nothing.
    func text(for snapshot: BatterySnapshot) -> String? {
        switch self {
        case .percentage:
            // Without a battery the reader leaves 0 behind, which is not a charge.
            return snapshot.isPresent ? "\(snapshot.percentage)%" : nil
        case .timeRemaining:
            return snapshot.remainingMinutes.map { BatteryDecoding.formatDuration(minutes: $0) }
        case .chargingStatus:
            return snapshot.shortStatusText
        case .batteryWatts:
            return snapshot.batteryWatts.map { Fmt.watts($0, signed: true) }
        case .adapterWatts:
            return snapshot.isPluggedIn ? snapshot.adapterWatts.map { Fmt.watts($0) } : nil
        case .systemWatts:
            return snapshot.systemWatts.map { Fmt.watts($0) }
        case .capacity:
            return snapshot.currentCapacityMAh.map { Fmt.mAh($0) }
        case .temperature:
            return snapshot.temperature.map { Fmt.celsius($0) }
        }
    }
}

/// What the menu bar shows, persisted in `UserDefaults`.
struct MenuBarConfig: Equatable {
    var showsIcon: Bool
    var items: [MenuBarItem]

    static let iconKey = "menuBarShowsIcon"
    static let itemsKey = "menuBarItems"
    static let separator = " · "

    static let `default` = MenuBarConfig(showsIcon: true, items: [.percentage])

    init(showsIcon: Bool, items: [MenuBarItem]) {
        self.showsIcon = showsIcon
        // Kept in declaration order so the menu bar layout is predictable no
        // matter in which order the fields were switched on.
        self.items = MenuBarItem.allCases.filter(items.contains)
    }

    init(showsIcon: Bool, rawItems: String) {
        let selected = rawItems.split(separator: ",").map(String.init)
        self.init(showsIcon: showsIcon,
                  items: selected.compactMap(MenuBarItem.init(rawValue:)))
    }

    var rawItems: String { items.map(\.rawValue).joined(separator: ",") }

    static func load(from defaults: UserDefaults = .standard) -> MenuBarConfig {
        MenuBarConfig(showsIcon: defaults.object(forKey: iconKey) as? Bool ?? `default`.showsIcon,
                      rawItems: defaults.string(forKey: itemsKey) ?? `default`.rawItems)
    }

    var needsDetailedRead: Bool { items.contains(where: \.requiresDetailedRead) }

    /// Hiding the icon *and* every field would leave an invisible menu bar item
    /// that cannot be clicked again, so the icon comes back on its own.
    var effectiveShowsIcon: Bool { showsIcon || items.isEmpty }

    /// Same rule at render time: fields can all be unavailable (no battery,
    /// unplugged), and the item must still be clickable.
    func showsIcon(for snapshot: BatterySnapshot) -> Bool {
        effectiveShowsIcon || text(for: snapshot) == nil
    }

    func text(for snapshot: BatterySnapshot) -> String? {
        let parts = items.compactMap { $0.text(for: snapshot) }
        return parts.isEmpty ? nil : parts.joined(separator: Self.separator)
    }

    func contains(_ item: MenuBarItem) -> Bool { items.contains(item) }

    func toggling(_ item: MenuBarItem) -> MenuBarConfig {
        MenuBarConfig(showsIcon: showsIcon,
                      items: contains(item) ? items.filter { $0 != item } : items + [item])
    }
}
