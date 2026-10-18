import Foundation

/// One device as a widget draws it. The apps write the list to the App Group
/// container and the widget extension reads it: the extension never opens the
/// SwiftData store, which stays where it is and needs no migration.
///
/// Compiled into the apps and into the widget extensions.
struct WidgetDevice: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    /// An SF Symbol: `iphone`, `ipad`, `laptopcomputer`.
    var symbol: String
    var percentage: Int
    var isCharging: Bool
    var isPluggedIn: Bool
    var lowPowerMode: Bool
    /// When this reading was taken, for the widget to tell an old one apart.
    var date: Date
    /// The device the widget is on, listed first.
    var isCurrent: Bool

    static let appGroup = "group.cl.franciscosolis.openbattery"

    /// Nil where the App Group is not granted: a Debug Mac build, an unsigned
    /// simulator run. The apps then simply write nothing.
    static var fileURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appending(path: "devices.json")
    }

    static func read() -> [WidgetDevice] {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([WidgetDevice].self, from: data)) ?? []
    }

    /// The devices a widget was set to show, in the order they were picked.
    /// Nothing picked shows them all; so does a pick whose devices have all
    /// left the list, rather than a widget with nothing in it.
    static func picked(_ ids: [String]?, from all: [WidgetDevice]) -> [WidgetDevice] {
        let picked = (ids ?? []).compactMap { id in all.first { $0.id == id } }
        return picked.isEmpty ? all : picked
    }

    /// An hour without a reading means a device asleep or away, as in the app.
    func isStale(at now: Date) -> Bool { now.timeIntervalSince(date) > 3600 }
}
