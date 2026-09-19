import Foundation
import NIOCore

/// A device as usbmuxd sees it, before anything is known about its battery.
struct MuxDevice: Equatable, Identifiable {
    let deviceID: Int
    let udid: String
    let isNetwork: Bool

    /// The UDID, not the device ID: usbmuxd hands out a new device ID every time
    /// the same device reappears.
    var id: String { udid }
}

/// usbmuxd proxies devices attached over Wi-Fi as well as over USB — verified
/// against a network-attached iPad — so one transport covers both and nothing
/// here parses sockaddrs or opens a TCP connection of its own.
enum USBMux {
    static let lockdownPort: UInt16 = 62078

    private static let handshake: [String: Any] = [
        "ClientVersionString": "OpenBattery",
        "ProgName": "OpenBattery",
        "kLibUSBMuxVersion": 3,
    ]

    static func listDevices(_ connection: PlistConnection) async throws -> [MuxDevice] {
        let reply = try await connection.send(message("ListDevices"))
        let list = reply["DeviceList"] as? [[String: Any]] ?? []
        return list.compactMap(device(from:))
    }

    /// Turns the connection into a pipe to `port` on the device. The port is
    /// big-endian *inside* the little-endian header — the one byte-order trap in
    /// the protocol.
    static func connect(_ connection: PlistConnection, deviceID: Int, port: UInt16) async throws {
        let reply = try await connection.send(message("Connect", [
            "DeviceID": deviceID,
            "PortNumber": Int(port.bigEndian),
        ]))
        guard reply["Number"] as? Int == 0 else {
            throw DeviceError.muxRefused("port \(port): \(reply["Number"] ?? "no result")")
        }
        try await connection.useLockdownFraming()
    }

    /// The pair record macOS keeps for this device. usbmuxd reads
    /// /var/db/lockdown for us, which is the whole reason this app needs neither
    /// Full Disk Access nor a pairing flow of its own.
    static func readPairRecord(_ connection: PlistConnection,
                               udid: String) async throws -> PairRecord {
        let reply = try await connection.send(message("ReadPairRecord", [
            "PairRecordID": udid,
        ]))
        guard let blob = reply["PairRecordData"] as? Data,
              let plist = try? PropertyListSerialization
                  .propertyList(from: blob, options: [], format: nil) as? [String: Any],
              let record = PairRecord(plist: plist) else {
            throw DeviceError.notPaired
        }
        return record
    }

    private static func message(_ type: String,
                                _ extra: [String: Any] = [:]) -> [String: Any] {
        handshake.merging(extra) { _, new in new }.merging(["MessageType": type]) { _, new in new }
    }

    private static func device(from entry: [String: Any]) -> MuxDevice? {
        guard let deviceID = entry["DeviceID"] as? Int,
              let properties = entry["Properties"] as? [String: Any],
              let udid = properties["SerialNumber"] as? String else { return nil }
        return MuxDevice(deviceID: deviceID, udid: udid,
                         isNetwork: properties["ConnectionType"] as? String == "Network")
    }
}
