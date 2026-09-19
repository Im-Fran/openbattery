import Foundation
import NIOCore

/// The conversation with `lockdownd`, the service on port 62078 that every other
/// service on an Apple device is reached through.
///
/// Two things learned from a real device and worth keeping written down: every
/// error closes the connection, so retrying means reconnecting; and
/// `ValidatePair` is answered by hanging up, so the pair record is checked by
/// starting a session, which reports `InvalidHostID` when it is no good.
final class LockdownClient {
    private let connection: PlistConnection
    private let label = "OpenBattery"

    private init(connection: PlistConnection) { self.connection = connection }

    static func open(group: EventLoopGroup, deviceID: Int) async throws -> LockdownClient {
        let connection = try await PlistConnection.connectToUSBMux(group: group)
        try await USBMux.connect(connection, deviceID: deviceID, port: USBMux.lockdownPort)
        let client = LockdownClient(connection: connection)
        guard try await client.request(["Request": "QueryType"])["Type"] as? String
                == "com.apple.mobile.lockdown" else {
            throw DeviceError.malformedReply
        }
        return client
    }

    func close() async { await connection.close() }

    @discardableResult
    func request(_ payload: [String: Any]) async throws -> [String: Any] {
        var message = payload
        message["Label"] = label
        message["ProtocolVersion"] = "2"
        let reply = try await connection.send(message)
        if let error = reply["Error"] as? String { throw DeviceError.lockdown(error) }
        return reply
    }

    func value(_ key: String) async throws -> Any? {
        try await request(["Request": "GetValue", "Key": key])["Value"]
    }

    func string(_ key: String) async throws -> String? {
        try await value(key) as? String
    }

    /// Opens the session and upgrades it, which is what every service below
    /// depends on. `StartSession` is also the pair record's only real check.
    func startSession(_ record: PairRecord) async throws {
        let reply = try await request([
            "Request": "StartSession",
            "HostID": record.hostID,
            "SystemBUID": record.systemBUID,
        ])
        if reply["EnableSessionSSL"] as? Bool == true {
            try await connection.startTLS(hostCertificatePEM: record.hostCertificatePEM,
                                          hostKeyPEM: record.hostKeyPEM)
        }
    }

    func startService(_ name: String) async throws -> (port: UInt16, needsTLS: Bool) {
        let reply = try await request(["Request": "StartService", "Service": name])
        guard let port = reply["Port"] as? Int, let port16 = UInt16(exactly: port) else {
            throw DeviceError.malformedReply
        }
        return (port16, reply["EnableServiceSSL"] as? Bool ?? false)
    }
}

/// `com.apple.mobile.diagnostics_relay`: the only way to reach the IORegistry of
/// an Apple device from a Mac, and so the only source of its cycle count.
final class DiagnosticsRelay {
    private let connection: PlistConnection

    private init(connection: PlistConnection) { self.connection = connection }

    static func open(group: EventLoopGroup, deviceID: Int, port: UInt16, needsTLS: Bool,
                     record: PairRecord) async throws -> DiagnosticsRelay {
        let connection = try await PlistConnection.connectToUSBMux(group: group)
        try await USBMux.connect(connection, deviceID: deviceID, port: port)
        if needsTLS {
            try await connection.startTLS(hostCertificatePEM: record.hostCertificatePEM,
                                          hostKeyPEM: record.hostKeyPEM)
        }
        return DiagnosticsRelay(connection: connection)
    }

    func ioRegistry(entryClass: String) async throws -> [String: Any] {
        let reply = try await connection.send(["Request": "IORegistry",
                                               "EntryClass": entryClass])
        guard reply["Status"] as? String == "Success",
              let diagnostics = reply["Diagnostics"] as? [String: Any],
              let registry = diagnostics["IORegistry"] as? [String: Any] else {
            throw DeviceError.malformedReply
        }
        return registry
    }

    func close() async {
        // Goodbye rather than a bare close: the relay logs a warning otherwise,
        // and a service left hanging is one fewer the device will hand out.
        _ = try? await connection.send(["Request": "Goodbye"])
        await connection.close()
    }
}
