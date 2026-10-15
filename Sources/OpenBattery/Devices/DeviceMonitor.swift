import Combine
import Foundation
import NIOPosix
import OSLog
import SwiftData

/// Publishes the devices usbmuxd can see and the battery of the selected one.
///
/// Nothing happens until a window asks for it: `start()` and `stop()` are called
/// by the same view lifecycle that already turns the Mac's detailed read on and
/// off, so a closed window costs nothing at all.
@MainActor
final class DeviceMonitor: ObservableObject {

    /// Which battery the Battery Info window is showing.
    enum Source: Equatable, Hashable {
        case mac
        case device(udid: String)
        /// The newest reading another device synced to iCloud: an iPhone that
        /// recorded itself, another Mac, or a device another Mac read by cable.
        case cloud(id: String)
    }

    @Published var source: Source = .mac {
        didSet {
            guard source != oldValue else { return }
            snapshot = nil
            failure = nil
            load = []
            // Charge history for a device only covers this session: it is read
            // over a cable, so there is nothing to read while the window is
            // closed and nothing worth keeping afterwards.
            chargeLog = SampleLog.charge
            capacityLog = Self.capacityLog(for: source).loaded()
            refreshNow()
        }
    }

    @Published private(set) var devices: [DeviceIdentity] = []
    /// Each device's own sync ID by UDID, once its OpenBattery has said which
    /// it is. On this Mac only; it is what lets one phone be one entry whether
    /// it arrives by cable, over the network or through iCloud.
    @Published private(set) var syncIDs = DeviceMonitor.storedSyncIDs

    /// The pairings learned so far, for `DeviceHub` too.
    static var storedSyncIDs: [String: String] {
        UserDefaults.standard.dictionary(forKey: syncIDsKey) as? [String: String] ?? [:]
    }
    /// The selected device's battery, or nil while the Mac is showing, the read
    /// has not landed yet, or it failed.
    @Published private(set) var snapshot: BatterySnapshot?
    @Published private(set) var failure: DeviceError?
    /// False in the sandboxed App Store build, where /var/run/usbmuxd is out of
    /// reach. The UI says so rather than showing an empty list.
    @Published private(set) var isSupported = true

    /// This session's charge readings, in memory only.
    @Published private(set) var chargeLog = SampleLog.charge
    /// Full charge capacity per device, kept across launches: a phone's health
    /// moves over months, and this is the only place that history can come from.
    @Published private(set) var capacityLog = SampleLog.capacity
    /// A minute of the device's own system load, for the Power tab.
    @Published private(set) var load: [BatteryMonitor.LoadSample] = []

    /// The same cadence the window already uses for the Mac.
    static let interval = BatteryMonitor.windowInterval
    /// How long a whole reading may take before it is called a failure. Long
    /// enough for a cold read over Wi-Fi, short enough that a locked phone
    /// explains itself rather than spinning.
    static let budget: TimeInterval = 12

    private static let log = Logger(subsystem: "cl.franciscosolis.openbattery",
                                    category: "devices")

    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private var sessions: [String: DeviceSession] = [:]
    private var timer: Timer?
    private var refreshTask: Task<Void, Never>?
    private var clients = 0
    private var inFlight = false
    private var lastIdentityAttempt: [String: Date] = [:]
    private static let syncIDsKey = "syncIDByUDID"

    deinit {
        timer?.invalidate()
        // The event loop group owns threads; a shutdown here is the only way
        // they end.
        try? group.syncShutdownGracefully()
    }

    func start() {
        clients += 1
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshNow() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        refreshNow()
    }

    func stop() {
        clients = max(0, clients - 1)
        guard clients == 0 else { return }
        timer?.invalidate()
        timer = nil
        // A reading still in flight would otherwise open a session again right
        // after this closed them all. Cancelling it also closes the channel it
        // is waiting on.
        refreshTask?.cancel()
        refreshTask = nil
        // Holding a lockdown session open against a device nobody is looking at
        // is how you end up on a battery-shaming blog post.
        let closing = sessions.values
        sessions = [:]
        Task { for session in closing { await session.close() } }
    }

    /// Every ID this device may be filed under on iCloud or the live link:
    /// its own once known, and the hash a Mac records it under until then.
    func cloudIDs(for udid: String) -> Set<String> {
        Set([SyncDevice.relayedID(udid: udid), udid] + [syncIDs[udid]].compactMap { $0 })
    }

    /// The selected device's name, for the places that should say which device
    /// rather than "the device".
    var selectedName: String? {
        guard case .device(let udid) = source else { return nil }
        return devices.first { $0.udid == udid }?.displayName
    }

    /// Capacity history is per device, so it needs a key per device. Everything
    /// else about the log — a year of months, one reading a day — is the same as
    /// the Mac's.
    private static func capacityLog(for source: Source) -> SampleLog {
        guard case .device(let udid) = source else { return .capacity }
        return SampleLog(key: "capacityHistory-\(udid)", unit: .month, buckets: 12,
                         minimumSpacing: 24 * 3600)
    }

    private func record(_ snapshot: BatterySnapshot) {
        if snapshot.isPresent {
            var charge = chargeLog
            // `to: nil` keeps it in memory: there is no reading to take while
            // the window is closed, so a stored log would be all gaps.
            if charge.record(snapshot.percentage, to: nil) { chargeLog = charge }
        }
        if let capacity = snapshot.fullChargeCapacityMAh {
            var log = capacityLog
            if log.record(capacity) { capacityLog = log }
        }
        guard let watts = snapshot.systemWatts else { return }
        let now = Date.now
        let oldest = now.addingTimeInterval(-BatteryMonitor.loadWindow)
        load = load.filter { $0.date > oldest }
            + [BatteryMonitor.LoadSample(date: now, watts: watts)]
    }

    /// Asks each device's OpenBattery which synced device it is. Only works
    /// while the app is open there, so a device not yet known is asked again
    /// every half minute rather than on every five-second read.
    private func learnSyncIDs() async {
        let pending = devices.filter { syncIDs[$0.udid] == nil }
        guard !pending.isEmpty else { return }
        let known = knownSyncIDs()
        for device in pending {
            if let last = lastIdentityAttempt[device.udid], Date.now.timeIntervalSince(last) < 30 { continue }
            lastIdentityAttempt[device.udid] = .now
            // Fresh every time, so no answer is ever worth recording.
            let nonce = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
            guard !Task.isCancelled, let session = sessions[device.udid],
                  let token = await session.identityToken(nonce: nonce),
                  let id = LiveLink.id(answering: token, nonce: nonce, among: known) else { continue }
            syncIDs[device.udid] = id
            UserDefaults.standard.set(syncIDs, forKey: Self.syncIDsKey)
        }
    }

    /// The IDs devices publish themselves under: on iCloud and nearby.
    // ponytail: fetches every self-published record to collect a handful of
    // IDs, at most twice a minute while a device is still unknown.
    private func knownSyncIDs() -> Set<String> {
        let own = FetchDescriptor<BatteryRecord>(predicate: #Predicate { $0.relayedBy == nil })
        let records = (try? CloudStore.shared.container.mainContext.fetch(own)) ?? []
        return Set(records.map(\.deviceID)).union(LiveLink.shared.peers.keys)
    }

    private func refreshNow() {
        guard !inFlight else { return }
        inFlight = true
        refreshTask = Task { [weak self] in
            await self?.refresh()
            self?.inFlight = false
        }
    }

    private func refresh() async {
        let muxDevices: [MuxDevice]
        do {
            let mux = try await PlistConnection.connectToUSBMux(group: group)
            muxDevices = try await USBMux.listDevices(mux)
            await mux.close()
            isSupported = true
        } catch {
            isSupported = (error as? DeviceError) != .transportUnavailable
            // The selected device keeps its place in the list even when usbmuxd
            // stops answering: a Picker whose selection matches no item renders
            // blank, and the error would then name no device at all.
            if case .device(let udid) = source {
                devices = devices.filter { $0.udid == udid }
                // Never nil: a window left with no error and no reading shows a
                // spinner that never resolves.
                failure = (error as? DeviceError) ?? .disconnected
                snapshot = nil
            } else {
                devices = []
            }
            return
        }

        // One entry per device even when usbmuxd reports the same one twice,
        // over USB and over Wi-Fi at once; USB wins because it is the faster
        // link and the one that can pair.
        var unique: [String: MuxDevice] = [:]
        for device in muxDevices {
            if let existing = unique[device.udid], !existing.isNetwork { continue }
            unique[device.udid] = device
        }
        // The window may have closed while usbmuxd was answering; opening
        // sessions now would leave them open with nobody watching.
        guard !Task.isCancelled, clients > 0 else { return }
        for (udid, device) in unique where sessions[udid] == nil {
            sessions[udid] = DeviceSession(device: device, group: group)
        }
        for udid in sessions.keys where unique[udid] == nil {
            let gone = sessions.removeValue(forKey: udid)
            Task { await gone?.close() }
        }

        // Identities already learned survive a refresh; a device that has not
        // been talked to yet shows its UDID until it has.
        let known = devices
        var listed: [DeviceIdentity] = []
        for (udid, device) in unique {
            if let known = known.first(where: { $0.udid == udid }) {
                listed.append(DeviceIdentity(udid: udid, name: known.name, model: known.model,
                                             systemVersion: known.systemVersion,
                                             isNetwork: device.isNetwork))
            } else {
                listed.append(DeviceIdentity(udid: udid, isNetwork: device.isNetwork))
            }
        }
        devices = listed.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
            == .orderedAscending }

        // A picker offering two forty-character UDIDs is no picker at all, so
        // every device gets asked its name once, whether or not it is selected.
        for device in devices where device.name == nil {
            guard !Task.isCancelled, let session = sessions[device.udid] else { break }
            guard let named = try? await session.identify(),
                  let index = devices.firstIndex(where: { $0.udid == device.udid }) else { continue }
            devices[index] = DeviceIdentity(udid: named.udid, name: named.name, model: named.model,
                                            systemVersion: named.systemVersion,
                                            isNetwork: devices[index].isNetwork)
        }

        await learnSyncIDs()

        guard case .device(let udid) = source else { return }
        // A device that vanished while it was being shown keeps its place in the
        // picker and says so. Silently repointing every tab at the Mac would
        // change the subject of the window without telling anyone.
        guard let session = sessions[udid] else {
            if let vanished = known.first(where: { $0.udid == udid }) {
                devices.append(vanished)
            }
            snapshot = nil
            failure = .disconnected
            return
        }
        do {
            let reading = try await readWithBudget(session)
            snapshot = reading.snapshot
            failure = nil
            if let index = devices.firstIndex(where: { $0.udid == udid }) {
                devices[index] = reading.identity
            }
            record(reading.snapshot)
            // Under the phone's own ID once known, so its readings and this
            // one are one device everywhere; until then under a hash, never
            // the UDID. The store spaces these out itself, so a five-second
            // cadence costs nothing extra.
            let cloudID = syncIDs[udid] ?? SyncDevice.relayedID(udid: udid)
            CloudStore.shared.publish(reading.snapshot, for: SyncDevice(
                id: cloudID, name: reading.identity.displayName,
                model: reading.identity.model ?? "", relayedBy: SyncDevice.current.name))
            // And straight to the devices nearby, which need not wait for
            // iCloud's quarter-hour spacing: the device itself among them.
            LiveLink.shared.share(RelayedReading(mac: SyncDevice.current.name, date: .now,
                                                 snapshot: reading.snapshot), for: cloudID)
        } catch let error as DeviceError {
            failure = error
            snapshot = nil
            // The payload exists for this line. A port number belongs in a log,
            // never in the message someone reads.
            if case .muxRefused(let detail) = error {
                Self.log.error("usbmux refused: \(detail, privacy: .public)")
            }
            if case .lockdown(let code) = error {
                Self.log.error("lockdown refused: \(code, privacy: .public)")
            }
        } catch {
            failure = .disconnected
            snapshot = nil
        }
    }

    /// One budget for the whole reading, not one per connection: a cold read
    /// opens three in a row, and three deadlines in series would leave someone
    /// watching an unexplained spinner for half a minute.
    private func readWithBudget(
        _ session: DeviceSession
    ) async throws -> (snapshot: BatterySnapshot, identity: DeviceIdentity) {
        try await withThrowingTaskGroup(of: (snapshot: BatterySnapshot,
                                             identity: DeviceIdentity).self) { group in
            group.addTask { try await session.read() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(Self.budget * 1_000_000_000))
                throw DeviceError.timedOut
            }
            // Whichever finishes first: cancelling the group closes the channel
            // the other task is waiting on.
            defer { group.cancelAll() }
            guard let reading = try await group.next() else { throw DeviceError.timedOut }
            return reading
        }
    }
}
