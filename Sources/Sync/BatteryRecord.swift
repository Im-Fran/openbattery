import Foundation
import SwiftData

/// One reading of one device's battery, kept in the person's private iCloud
/// database so every Mac, iPhone and iPad they sign into can see it — no shared
/// network, no cable.
///
/// CloudKit-backed SwiftData wants every property optional or defaulted and no
/// unique constraints, hence the defaults. The snapshot travels as JSON rather
/// than as columns: a field added to `BatterySnapshot` later needs no schema
/// migration, and an older build simply ignores it.
@Model
final class BatteryRecord {
    /// A UUID the device minted for itself, or the UDID of a device a Mac read
    /// over usbmuxd.
    var deviceID: String = ""
    var deviceName: String = ""
    /// `iPhone17,1`, `Mac15,7` and friends.
    var deviceModel: String = ""
    /// The Mac that read this device over a cable or Wi-Fi; nil when the
    /// device recorded itself.
    var relayedBy: String?
    var date: Date = Date.distantPast
    /// Kept beside the payload so charts and queries need not decode it.
    var percentage: Int = 0
    var payload: Data?

    init(device: SyncDevice, snapshot: BatterySnapshot, date: Date = .now) {
        deviceID = device.id
        deviceName = device.name
        deviceModel = device.model
        relayedBy = device.relayedBy
        self.date = date
        percentage = snapshot.percentage
        payload = try? JSONEncoder().encode(snapshot)
    }

    var snapshot: BatterySnapshot? {
        payload.flatMap { try? JSONDecoder().decode(BatterySnapshot.self, from: $0) }
    }

    var device: SyncDevice {
        SyncDevice(id: deviceID, name: deviceName, model: deviceModel, relayedBy: relayedBy)
    }
}

/// Who a record belongs to.
struct SyncDevice: Hashable, Identifiable {
    var id: String
    var name: String
    var model: String
    var relayedBy: String?

    enum Kind { case mac, iPhone, iPad, watch }

    var kind: Kind {
        if model.hasPrefix("iPhone") { return .iPhone }
        if model.hasPrefix("iPad") { return .iPad }
        if model.hasPrefix("Watch") { return .watch }
        return .mac
    }

    var symbol: String {
        switch kind {
        case .mac: return "laptopcomputer"
        case .iPhone: return "iphone"
        case .iPad: return "ipad"
        case .watch: return "applewatch"
        }
    }
}

/// The newest reading of one device, which is what a device list shows.
struct SyncedDevice: Identifiable, Equatable {
    var device: SyncDevice
    var date: Date
    var snapshot: BatterySnapshot

    var id: String { device.id }

    /// One entry per device, newest reading first. `records` may be in any
    /// order; records whose payload no longer decodes are skipped.
    static func latest(from records: [BatteryRecord]) -> [SyncedDevice] {
        // Newest first, so a device whose latest payload does not decode falls
        // back to its previous reading instead of vanishing.
        var seen: Set<String> = []
        var result: [SyncedDevice] = []
        for record in records.sorted(by: { $0.date > $1.date }) where !seen.contains(record.deviceID) {
            guard let snapshot = record.snapshot else { continue }
            seen.insert(record.deviceID)
            result.append(SyncedDevice(device: record.device, date: record.date, snapshot: snapshot))
        }
        return result
    }

    /// The reading a Mac took of this same iPhone over usbmuxd, which carries
    /// what iOS never tells an app about itself: health, cycles, capacity.
    ///
    /// An iPhone does not know its own UDID, so the two are matched on model.
    // ponytail: two phones of the same model on one account would match each
    // other; add a name tiebreak if that ever shows up.
    static func relayed(matching model: String, in devices: [SyncedDevice]) -> SyncedDevice? {
        devices.first { $0.device.relayedBy != nil && $0.device.model == model }
    }

    /// One entry per physical device for a list: an iPhone that publishes
    /// itself and was also read by a Mac would otherwise appear twice under
    /// the same name. The phone's own entry stays — it is the one that keeps
    /// updating — and borrows the health iOS keeps from it.
    static func merged(_ devices: [SyncedDevice]) -> [SyncedDevice] {
        var absorbed: Set<String> = []
        var result = devices.map { device -> SyncedDevice in
            guard device.device.relayedBy == nil, device.device.kind != .mac,
                  let relayed = relayed(matching: device.device.model, in: devices) else { return device }
            absorbed.insert(relayed.id)
            var merged = device
            let health = relayed.snapshot
            merged.snapshot.cycleCount = merged.snapshot.cycleCount ?? health.cycleCount
            merged.snapshot.fullChargeCapacityMAh = merged.snapshot.fullChargeCapacityMAh ?? health.fullChargeCapacityMAh
            merged.snapshot.designCapacityMAh = merged.snapshot.designCapacityMAh ?? health.designCapacityMAh
            merged.snapshot.nominalCapacityMAh = merged.snapshot.nominalCapacityMAh ?? health.nominalCapacityMAh
            merged.snapshot.serialNumber = merged.snapshot.serialNumber ?? health.serialNumber
            return merged
        }
        result.removeAll { absorbed.contains($0.id) }
        return result
    }
}
