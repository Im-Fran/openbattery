import Foundation
import SwiftData
import WidgetKit

/// Keeps the widgets' copy of the device list current: after every reading
/// this device saves and every import from iCloud, the list is rebuilt, and the
/// widgets are reloaded only when it changed — WidgetKit budgets reloads.
@MainActor
enum WidgetFeed {
    static func update() {
        guard let url = WidgetDevice.fileURL else { return }
        let records = (try? CloudStore.shared.container.mainContext.fetch(FetchDescriptor<BatteryRecord>())) ?? []
        let devices = entries(SyncedDevice.listed(records: records, live: [], liveRelayed: [:]),
                              currentID: SyncDevice.current.id)
        guard let data = try? JSONEncoder().encode(devices),
              data != (try? Data(contentsOf: url)) else { return }
        try? data.write(to: url, options: .atomic)
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// This device first, then the rest by name.
    static func entries(_ devices: [SyncedDevice], currentID: String) -> [WidgetDevice] {
        let entries: [WidgetDevice] = devices.map { synced in
            let snapshot = synced.snapshot
            return WidgetDevice(id: synced.id, name: synced.device.name, symbol: synced.device.symbol,
                                percentage: snapshot.percentage, isCharging: snapshot.isCharging,
                                isPluggedIn: snapshot.isPluggedIn, lowPowerMode: snapshot.lowPowerMode,
                                date: synced.date, isCurrent: synced.id == currentID)
        }
        return entries.sorted { (lhs: WidgetDevice, rhs: WidgetDevice) -> Bool in
            if lhs.isCurrent != rhs.isCurrent { return lhs.isCurrent }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}
