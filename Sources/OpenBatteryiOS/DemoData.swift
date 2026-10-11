#if DEBUG
import Foundation
import SwiftData

/// A week of believable history for three devices, so the Devices tab can be
/// looked at in a simulator that has no Mac and no iCloud account behind it.
///
/// Opt-in with the `-demoData` launch argument, and only once per store. Beside
/// whatever this device records for itself, so "This iPhone" shows up too.
/// Never with a simulator signed into a real iCloud account: these fake
/// readings would sync to every Mac on it.
enum DemoData {
    @MainActor static func seedIfRequested(into context: ModelContext) {
        guard ProcessInfo.processInfo.arguments.contains("-demoData"),
              (try? context.fetchCount(FetchDescriptor<BatteryRecord>(
                  predicate: #Predicate { $0.deviceID == "demo-mac" }))) == 0 else { return }
        let now = Date.now
        let mac = SyncDevice(id: "demo-mac", name: "MacBook Pro", model: "Mac15,7")
        let iPad = SyncDevice(id: "demo-ipad", name: "iPad Pro", model: "iPad16,3")
        let iPhone = SyncDevice(id: "demo-iphone", name: "iPhone 16 Pro", model: "iPhone17,1", relayedBy: mac.name)

        // Asleep overnight, so its chart has honest gaps; on the charger for
        // a stretch each morning and afternoon.
        insert(mac, into: context, history(until: now, start: 64, chargeRate: 28, drainRate: 9,
                                           awake: { !(0..<8).contains($0) },
                                           plugged: { hour, _, _ in (9..<12).contains(hour) || (14..<17).contains(hour) },
                                           snapshot: macSnapshot))
        // Lasts days on a charge and gets plugged in once it runs low. Last
        // heard from three hours ago, so the list shows a stale reading.
        insert(iPad, into: context, history(until: now.addingTimeInterval(-3 * 3600), start: 71, chargeRate: 30, drainRate: 1.6,
                                            plugged: { _, level, was in level < 20 || (was && level < 100) },
                                            snapshot: { level, plugged, charging in
                                                BatterySnapshot(percentage: level, isCharging: charging, isPluggedIn: plugged,
                                                                isFullyCharged: plugged && !charging, isPresent: true,
                                                                lowPowerMode: !plugged && level < 25)
                                            }))
        // Charged overnight, read by the Mac over Wi-Fi with the health iOS
        // keeps from apps.
        insert(iPhone, into: context, history(until: now.addingTimeInterval(-20 * 60), start: 88, chargeRate: 22, drainRate: 5.5,
                                              plugged: { hour, _, _ in hour >= 23 || hour < 7 },
                                              snapshot: iPhoneSnapshot))
        try? context.save()
    }

    private static func insert(_ device: SyncDevice, into context: ModelContext, _ readings: [(Date, BatterySnapshot)]) {
        for (date, snapshot) in readings {
            context.insert(BatteryRecord(device: device, snapshot: snapshot, date: date))
        }
    }

    /// Steps a battery through the week ending at `end`, every 30 minutes.
    /// `plugged` gets the hour, the level and whether it was plugged in the
    /// step before, which is all a charging habit needs.
    private static func history(
        until end: Date, start: Double, chargeRate: Double, drainRate: Double,
        awake: (Int) -> Bool = { _ in true },
        plugged: (Int, Double, Bool) -> Bool,
        snapshot: (Int, Bool, Bool) -> BatterySnapshot
    ) -> [(Date, BatterySnapshot)] {
        let step: TimeInterval = 30 * 60
        var level = start
        var wasPlugged = false
        var readings: [(Date, BatterySnapshot)] = []
        var date = end.addingTimeInterval(-7 * 24 * 3600)
        while date <= end {
            defer { date += step }
            let hour = Calendar.current.component(.hour, from: date)
            guard awake(hour) else { continue }
            let isPlugged = plugged(hour, level, wasPlugged)
            wasPlugged = isPlugged
            let rate = isPlugged ? chargeRate : -drainRate * Double.random(in: 0.6...1.5)
            level = min(100, max(3, level + rate * step / 3600))
            let percentage = Int(level.rounded())
            readings.append((date, snapshot(percentage, isPlugged, isPlugged && percentage < 100)))
        }
        return readings
    }

    private static func macSnapshot(level: Int, plugged: Bool, charging: Bool) -> BatterySnapshot {
        let system = Double.random(in: 6...22)
        let battery = charging ? Double.random(in: 30...60) : plugged ? 0 : -system
        var s = BatterySnapshot(percentage: level, isCharging: charging, isPluggedIn: plugged,
                                isFullyCharged: plugged && !charging, isPresent: true)
        s.timeToFull = charging ? (100 - level) * 2 : nil
        s.timeToEmpty = plugged ? nil : level * 4
        s.batteryWatts = battery
        s.systemWatts = system
        if plugged {
            s.adapterWatts = system + max(battery, 0)
            s.adapterRatedWatts = 140
            s.adapterVolts = 28
            s.adapterAmps = s.adapterWatts.map { $0 / 28 }
            s.adapterDescription = "140W USB-C Power Adapter"
        }
        s.volts = 11.4 + Double(level) / 100 * 1.6
        s.amps = s.volts.map { battery / $0 }
        s.temperature = charging ? Double.random(in: 33...37) : Double.random(in: 28...32)
        s.currentCapacityMAh = 8_120 * level / 100
        s.fullChargeCapacityMAh = 8_120
        s.designCapacityMAh = 8_579
        s.cycleCount = 142
        return s
    }

    private static func iPhoneSnapshot(level: Int, plugged: Bool, charging: Bool) -> BatterySnapshot {
        var s = BatterySnapshot(percentage: level, isCharging: charging, isPluggedIn: plugged,
                                isFullyCharged: plugged && !charging, isPresent: true)
        s.volts = 3.7 + Double(level) / 100 * 0.6
        s.temperature = charging ? Double.random(in: 30...34) : Double.random(in: 26...30)
        s.fullChargeCapacityMAh = 3_310
        s.designCapacityMAh = 3_582
        s.cycleCount = 213
        return s
    }
}
#endif
