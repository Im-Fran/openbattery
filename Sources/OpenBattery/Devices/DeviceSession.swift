import Foundation
import NIOCore
import NIOPosix

/// One device's live connection: the lockdown session and the diagnostics relay
/// opened over it, kept open so a reading costs a single round trip.
///
/// An actor because the UI asks for readings from the main thread while the
/// connection lives on an event loop, and because a torn-down session must never
/// be rebuilt twice at once.
actor DeviceSession {
    private let device: MuxDevice
    private let group: EventLoopGroup
    private var lockdown: LockdownClient?
    private var relay: DiagnosticsRelay?

    private(set) var identity: DeviceIdentity

    init(device: MuxDevice, group: EventLoopGroup) {
        self.device = device
        self.group = group
        identity = DeviceIdentity(udid: device.udid, isNetwork: device.isNetwork)
    }

    /// Reads the battery, connecting first if needed. Any failure tears the
    /// connection down so the next attempt starts clean — lockdownd hangs up on
    /// its own errors, so a live-looking session may already be dead.
    func read() async throws -> (snapshot: BatterySnapshot, identity: DeviceIdentity) {
        do {
            let relay = try await connectedRelay()
            let registry = try await relay.ioRegistry(entryClass: "AppleSmartBattery")
            // A reply we cannot make sense of is an error, not a phone without a
            // battery, and never a confident 0%.
            guard DeviceBattery.isBatteryReply(registry) else { throw DeviceError.malformedReply }
            return (DeviceBattery.decode(ioRegistry: registry), identity)
        } catch {
            await close()
            throw error
        }
    }

    /// Asks the device what it is called, on a connection of its own that is
    /// closed straight away. `DeviceName` and `ProductType` are readable without
    /// a session, so this costs no TLS handshake and leaves nothing open — which
    /// is what makes it reasonable to do for every device in the list, whether
    /// or not anyone selects it. Without it the picker would offer UDIDs.
    func identify() async throws -> DeviceIdentity {
        guard identity.name == nil else { return identity }
        let client = try await LockdownClient.open(group: group, deviceID: device.deviceID)
        defer { Task { await client.close() } }
        identity.name = try? await client.string("DeviceName")
        identity.model = try? await client.string("ProductType")
        identity.systemVersion = try? await client.string("ProductVersion")
        return identity
    }

    func close() async {
        await relay?.close()
        relay = nil
        await lockdown?.close()
        lockdown = nil
    }

    private func connectedRelay() async throws -> DiagnosticsRelay {
        if let relay { return relay }

        // The pair record macOS already holds, by way of usbmuxd.
        let mux = try await PlistConnection.connectToUSBMux(group: group)
        let record = try await USBMux.readPairRecord(mux, udid: device.udid)
        await mux.close()

        let client = try await LockdownClient.open(group: group, deviceID: device.deviceID)
        try await client.startSession(record)

        // Who the device is, now that it will tell us. Worth having but not
        // worth failing a reading over.
        identity.name = try? await client.string("DeviceName")
        identity.model = try? await client.string("ProductType")
        identity.systemVersion = try? await client.string("ProductVersion")

        let service = try await client.startService("com.apple.mobile.diagnostics_relay")
        let relay = try await DiagnosticsRelay.open(group: group, deviceID: device.deviceID,
                                                    port: service.port,
                                                    needsTLS: service.needsTLS, record: record)
        lockdown = client
        self.relay = relay
        return relay
    }
}
