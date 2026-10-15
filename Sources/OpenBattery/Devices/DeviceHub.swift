import Foundation
import NIOPosix
import OSLog

/// Reads an iPhone or iPad over usbmuxd when it asks, from nearby, over the
/// live link: iOS keeps health, cycles and power from the device's own app,
/// so a Mac on the same network reads them for it and hands them back.
///
/// Separate from `DeviceMonitor`, which only runs while the Battery Info window
/// is open; this answers whenever the app is running, one read per request.
@MainActor
final class DeviceHub {
    static let shared = DeviceHub()

    /// Mac reads are a lockdown session each; a device asking every minute
    /// gets at most one per this.
    private static let spacing: TimeInterval = 60

    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private var lastServed: [String: Date] = [:]
    private static let log = Logger(subsystem: "cl.franciscosolis.openbattery", category: "hub")

    private init() {}

    func start() {
        LiveLink.shared.onReadingRequest = { [weak self] peer in
            Task { await self?.serve(peer) }
        }
    }

    private func serve(_ peer: SyncDevice) async {
        if let last = lastServed[peer.id], Date.now.timeIntervalSince(last) < Self.spacing { return }
        lastServed[peer.id] = .now
        guard let device = await find(peer) else {
            Self.log.info("no usbmuxd device for a nearby \(peer.model, privacy: .public)")
            return
        }
        let session = DeviceSession(device: device, group: group)
        defer { Task { await session.close() } }
        do {
            let reading = try await session.read()
            let now = Date.now
            CloudStore.shared.publish(reading.snapshot, for: SyncDevice(
                id: peer.id, name: reading.identity.displayName, model: peer.model,
                relayedBy: SyncDevice.current.name), at: now, force: true)
            LiveLink.shared.share(RelayedReading(mac: SyncDevice.current.name, date: now,
                                                 snapshot: reading.snapshot), for: peer.id)
        } catch {
            Self.log.error("hub read failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The usbmuxd device that is `peer`: by the pairing `DeviceMonitor`
    /// learned over a cable, or else the only one of its model.
    private func find(_ peer: SyncDevice) async -> MuxDevice? {
        guard let mux = try? await PlistConnection.connectToUSBMux(group: group),
              let listed = try? await USBMux.listDevices(mux) else { return nil }
        await mux.close()
        // USB over Wi-Fi when a device shows up both ways: faster, and the one
        // the identity port answers on.
        var unique: [String: MuxDevice] = [:]
        for device in listed where unique[device.udid]?.isNetwork ?? true {
            unique[device.udid] = device
        }
        let paired = DeviceMonitor.storedSyncIDs
        if let match = unique.values.first(where: { paired[$0.udid] == peer.id }) { return match }

        // ponytail: two devices of the same model, neither ever cabled, are
        // told apart by nothing; then this reads neither rather than guess.
        var sameModel: [MuxDevice] = []
        for device in unique.values where paired[device.udid] == nil {
            let identity = try? await DeviceSession(device: device, group: group).identify()
            if identity?.model == peer.model { sameModel.append(device) }
        }
        return sameModel.count == 1 ? sameModel[0] : nil
    }
}
