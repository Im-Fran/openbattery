import CryptoKit
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
    /// Arrived over the local network just now rather than through iCloud.
    var isLive = false
    /// The newest reading a Mac took of this device over usbmuxd: the power
    /// and health iOS never tells an app. Set by `listed`.
    var relayedReading: RelayedReading?

    var id: String { device.id }

    /// Live readings replace the synced ones of the same device; a device
    /// seen only live, before its first record syncs, is added. A Mac's
    /// reading of it stays, for the health a live reading never carries.
    static func overlaying(_ live: [SyncedDevice], on synced: [SyncedDevice]) -> [SyncedDevice] {
        let liveIDs = Set(live.map(\.id))
        return live.sorted { $0.device.name.localizedStandardCompare($1.device.name) == .orderedAscending }
            + synced.filter { $0.device.relayedBy != nil || !liveIDs.contains($0.id) }
    }

    /// One entry per device and source, newest reading first: a phone's own
    /// record and a Mac's reading of it share an ID once the Mac has learned
    /// it, and `merged` folds the two. `records` may be in any order; records
    /// whose payload no longer decodes are skipped.
    static func latest(from records: [BatteryRecord]) -> [SyncedDevice] {
        // Newest first, so a device whose latest payload does not decode falls
        // back to its previous reading instead of vanishing.
        var seen: Set<String> = []
        var result: [SyncedDevice] = []
        for record in records.sorted(by: { $0.date > $1.date }) {
            let key = "\(record.deviceID)|\(record.relayedBy != nil)"
            guard !seen.contains(key), let snapshot = record.snapshot else { continue }
            seen.insert(key)
            result.append(SyncedDevice(device: record.device, date: record.date, snapshot: snapshot))
        }
        return result
    }

    /// The reading a Mac took of this same iPhone over usbmuxd, which carries
    /// what iOS never tells an app about itself: health, cycles, capacity.
    static func relayed(for device: SyncDevice, in devices: [SyncedDevice]) -> SyncedDevice? {
        relayedIndex(for: device, in: devices).map { devices[$0] }
    }

    /// By ID once the Mac has learned the phone's (see `LiveLink.identityToken`),
    /// by model before that.
    // ponytail: the model fallback lets two phones of the same model, read by
    // a Mac that has not learned their IDs yet, borrow each other's health.
    private static func relayedIndex(for device: SyncDevice, in devices: [SyncedDevice]) -> Int? {
        let relayed = devices.indices.filter { devices[$0].device.relayedBy != nil }
        return relayed.first { devices[$0].id == device.id }
            ?? relayed.first { devices[$0].device.model == device.model }
    }

    /// Everything a device list shows: one entry per physical device, live
    /// readings over synced ones, and each device's freshest Mac reading,
    /// whether it came through iCloud or straight from a Mac nearby.
    static func listed(records: [BatteryRecord], live: [SyncedDevice],
                       liveRelayed: [String: RelayedReading]) -> [SyncedDevice] {
        merged(overlaying(live, on: latest(from: records))).map { device in
            var device = device
            if let fresh = liveRelayed[device.id], fresh.date > device.relayedReading?.date ?? .distantPast {
                device.relayedReading = fresh
            }
            return device
        }
    }

    /// The device's own charge with the power and health a Mac last read from
    /// it, for views that show one snapshot. The two can be minutes apart,
    /// which `RelayedReading.isStale` is there to say.
    var combinedSnapshot: BatterySnapshot {
        guard let relayed = relayedReading, device.relayedBy == nil else { return snapshot }
        var combined = relayed.snapshot
        combined.percentage = snapshot.percentage
        combined.isCharging = snapshot.isCharging
        combined.isPluggedIn = snapshot.isPluggedIn
        combined.isFullyCharged = snapshot.isFullyCharged
        combined.isPresent = snapshot.isPresent
        combined.lowPowerMode = snapshot.lowPowerMode
        return combined
    }

    /// One entry per physical device for a list: an iPhone that publishes
    /// itself and was also read by a Mac would otherwise appear twice under
    /// the same name. The phone's own entry stays — it is the one that keeps
    /// updating — and borrows the health iOS keeps from it.
    static func merged(_ devices: [SyncedDevice]) -> [SyncedDevice] {
        // By position: the two entries may share an ID.
        var absorbed = IndexSet()
        let result = devices.map { device -> SyncedDevice in
            if let mac = device.device.relayedBy {
                // A Mac's reading with nothing to fold into is its own record.
                var relayed = device
                relayed.relayedReading = RelayedReading(mac: mac, date: device.date, snapshot: device.snapshot)
                return relayed
            }
            guard device.device.kind != .mac,
                  let index = relayedIndex(for: device.device, in: devices) else { return device }
            absorbed.insert(index)
            var merged = device
            let source = devices[index]
            merged.relayedReading = RelayedReading(mac: source.device.relayedBy ?? "", date: source.date,
                                                   snapshot: source.snapshot)
            let health = devices[index].snapshot
            merged.snapshot.cycleCount = merged.snapshot.cycleCount ?? health.cycleCount
            merged.snapshot.fullChargeCapacityMAh = merged.snapshot.fullChargeCapacityMAh ?? health.fullChargeCapacityMAh
            merged.snapshot.designCapacityMAh = merged.snapshot.designCapacityMAh ?? health.designCapacityMAh
            merged.snapshot.nominalCapacityMAh = merged.snapshot.nominalCapacityMAh ?? health.nominalCapacityMAh
            merged.snapshot.serialNumber = merged.snapshot.serialNumber ?? health.serialNumber
            return merged
        }
        return result.indices.filter { !absorbed.contains($0) }.map { result[$0] }
    }
}

/// A Mac's usbmuxd reading of an iPhone or iPad, kept beside the device's own.
struct RelayedReading: Codable, Equatable {
    /// The Mac that read it, by name.
    var mac: String
    var date: Date
    var snapshot: BatterySnapshot

    /// Power moves by the second; past five minutes the numbers are history
    /// and the screen says so.
    static let freshness: TimeInterval = 5 * 60

    func isStale(at now: Date = .now) -> Bool { now.timeIntervalSince(date) > Self.freshness }
}

extension SyncDevice {
    /// The ID a Mac records a cabled device under before it has learned the
    /// device's own: a hash, so the UDID — a hardware identifier — never
    /// leaves the Mac.
    static func relayedID(udid: String) -> String {
        SHA256.hash(data: Data("OpenBattery relayed \(udid)".utf8))
            .prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}

/// Everything iCloud holds for one device, for the screen that shows and
/// clears it.
struct SyncedHistory: Identifiable, Equatable {
    /// Named as it last called itself.
    var device: SyncDevice
    var count: Int
    var oldest: Date
    var newest: Date

    var id: String { device.id }

    /// One entry per device ID, most recently heard from first.
    static func summaries(from records: [BatteryRecord]) -> [SyncedHistory] {
        Dictionary(grouping: records, by: \.deviceID).values.compactMap { group in
            guard let latest = group.max(by: { $0.date < $1.date }),
                  let first = group.min(by: { $0.date < $1.date }) else { return nil }
            return SyncedHistory(device: latest.device, count: group.count, oldest: first.date, newest: latest.date)
        }
        .sorted { $0.newest > $1.newest }
    }
}
