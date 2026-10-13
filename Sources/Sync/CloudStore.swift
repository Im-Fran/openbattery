import Foundation
import OSLog
import SwiftData
#if canImport(UIKit)
import UIKit
#endif

/// Writes this app's battery readings to iCloud and owns the container every
/// view reads them back from.
///
/// SwiftData mirrors the store to the private CloudKit database on its own;
/// nothing here talks to CloudKit directly. Without the iCloud entitlement —
/// a Debug Mac build signed without a profile, a simulator signed out of
/// iCloud — the very same store stays local, so nothing has to be compiled out.
@MainActor
final class CloudStore {
    #if DEBUG
    /// Demo readings stay in memory: a simulator signed into a real iCloud
    /// account would otherwise sync made-up devices to every Mac on it.
    static let shared = CloudStore(inMemory: ProcessInfo.processInfo.arguments.contains("-demoData"))
    #else
    static let shared = CloudStore()
    #endif

    /// Shared by the Mac and iOS apps, so each sees what the other wrote.
    static let containerID = "iCloud.cl.franciscosolis.openbattery"
    /// A reading every quarter hour is plenty for a chart covering days.
    nonisolated static let minimumSpacing: TimeInterval = 15 * 60
    /// History older than this is pruned by whichever device notices first.
    static let retention: TimeInterval = 30 * 24 * 3600

    let container: ModelContainer
    private var lastPublished: [String: (date: Date, snapshot: BatterySnapshot)] = [:]
    private var lastPrune: Date?
    private static let log = Logger(subsystem: "cl.franciscosolis.openbattery", category: "sync")

    init(inMemory: Bool = false) {
        // Listening before the store opens: the mirror's first setup and
        // export run right away, and a failure there is the one to show.
        _ = CloudSync.shared
        let schema = Schema([BatteryRecord.self])
        do {
            // Named: the Direct build is not sandboxed, so an unnamed store
            // would be ~/Library/Application Support/default.store, shared
            // with every other unsandboxed SwiftData app on the Mac.
            container = try ModelContainer(for: schema, configurations: ModelConfiguration(
                "OpenBattery", schema: schema, isStoredInMemoryOnly: inMemory,
                cloudKitDatabase: inMemory ? .none : .automatic))
        } catch {
            // A store that cannot open must not take the battery readings
            // down with it: fall back to memory and say why in the log.
            Self.log.error("store failed to open: \(error.localizedDescription, privacy: .public)")
            container = try! ModelContainer(for: schema, configurations: ModelConfiguration(
                schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        }
    }

    /// Records `snapshot` unless one was recorded for the same device moments
    /// ago. Safe to call on every refresh. `force` skips the spacing, for a
    /// person asking to sync right now.
    func publish(_ snapshot: BatterySnapshot, for device: SyncDevice, at now: Date = .now, force: Bool = false) {
        guard snapshot.isPresent else { return }
        let previous = lastPublished[device.id]
        guard force || Self.shouldRecord(snapshot, previous: previous, now: now) else { return }
        lastPublished[device.id] = (now, snapshot)

        let context = container.mainContext
        context.insert(BatteryRecord(device: device, snapshot: snapshot, date: now))
        pruneIfDue(context, now: now)
        do { try context.save() } catch {
            Self.log.error("save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Spaced out, except when the battery changes direction or jumps: being
    /// unplugged is worth recording the moment it happens.
    nonisolated static func shouldRecord(
        _ snapshot: BatterySnapshot,
        previous: (date: Date, snapshot: BatterySnapshot)?,
        now: Date
    ) -> Bool {
        guard let previous else { return true }
        if now.timeIntervalSince(previous.date) >= minimumSpacing { return true }
        let old = previous.snapshot
        return old.isCharging != snapshot.isCharging
            || old.isPluggedIn != snapshot.isPluggedIn
            || abs(old.percentage - snapshot.percentage) >= 5
    }

    /// Removes every reading of one device, here and, through the mirror, in
    /// iCloud. A device that is still running publishes again on its next read.
    func deleteHistory(of deviceID: String) throws {
        let context = container.mainContext
        // One by one rather than `delete(model:where:)`: a batch delete skips
        // the context, so an open @Query would keep listing the device.
        let records = try context.fetch(FetchDescriptor<BatteryRecord>(predicate: #Predicate { $0.deviceID == deviceID }))
        records.forEach(context.delete)
        try context.save()
        lastPublished[deviceID] = nil
    }

    private func pruneIfDue(_ context: ModelContext, now: Date) {
        if let lastPrune, now.timeIntervalSince(lastPrune) < 24 * 3600 { return }
        lastPrune = now
        let cutoff = now.addingTimeInterval(-Self.retention)
        try? context.delete(model: BatteryRecord.self, where: #Predicate { $0.date < cutoff })
    }
}

extension SyncDevice {
    /// This Mac, iPhone or iPad, under an ID it keeps for as long as the app
    /// stays installed.
    @MainActor static var current: SyncDevice {
        let defaults = UserDefaults.standard
        let key = "syncDeviceID"
        let id = defaults.string(forKey: key) ?? {
            let fresh = UUID().uuidString
            defaults.set(fresh, forKey: key)
            return fresh
        }()
        return SyncDevice(id: id, name: currentName, model: currentModel)
    }

    /// Overrides the name iOS gives away, which since iOS 16 is just "iPhone".
    static let nameKey = "syncDeviceName"

    @MainActor private static var currentName: String {
        // Trimmed, so a name of only spaces falls back instead of listing blank.
        if let custom = UserDefaults.standard.string(forKey: nameKey)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !custom.isEmpty { return custom }
        #if os(macOS)
        return Host.current().localizedName ?? "Mac"
        #else
        return UIDevice.current.name
        #endif
    }

    private static var currentModel: String {
        #if targetEnvironment(simulator)
        if let model = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return model }
        #endif
        #if os(macOS)
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var bytes = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &bytes, &size, nil, 0)
        return String(cString: bytes)
        #else
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        #endif
    }
}
