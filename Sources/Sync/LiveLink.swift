import CryptoKit
import Foundation
import Network
import Observation
import OSLog
import Security

/// Live readings between this person's Macs, iPhones and iPads on the same
/// network, while the apps are open: no iCloud round trip, no waiting for the
/// next quarter-hour record.
///
/// Every device advertises `_openbattery._tcp` over Bonjour and browses for
/// the others. Connections are TLS with a pre-shared key that lives in iCloud
/// Keychain, so only devices on the same Apple Account get past the handshake;
/// anyone else on the network sees a service name and nothing more.
@MainActor
@Observable
final class LiveLink {
    static let shared = LiveLink()

    /// Listed under NSBonjourServices in both Info.plists.
    static let serviceType = "_openbattery._tcp"

    /// The other devices connected right now, by device ID.
    private(set) var peers: [String: SyncedDevice] = [:]

    private var listener: NWListener?
    private var browser: NWBrowser?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    /// Which device each connection turned out to be, once it said hello.
    private var peerIDs: [ObjectIdentifier: String] = [:]
    private var buffers: [ObjectIdentifier: Data] = [:]
    private var key: Data?
    private var lastSnapshot: BatterySnapshot?

    private static let log = Logger(subsystem: "cl.franciscosolis.openbattery", category: "live")

    private init() {}

    // MARK: Lifecycle

    /// Advertises this device and connects to the others. Safe to call again.
    func start() {
        guard listener == nil else { return }
        guard let key = Self.sharedKey() else {
            // A Debug Mac build has no keychain access group to share through.
            Self.log.info("live link off: no shared key")
            return
        }
        self.key = key
        let me = SyncDevice.current
        do {
            let listener = try NWListener(using: Self.parameters(key: key))
            // The device ID as the service name: unique, and it tells the
            // browser which side should dial (see `browsed`).
            listener.service = NWListener.Service(name: me.id, type: Self.serviceType)
            listener.newConnectionHandler = { [weak self] connection in
                MainActor.assumeIsolated { self?.adopt(connection) }
            }
            listener.stateUpdateHandler = { state in
                if case .failed(let error) = state { Self.log.error("listener failed: \(error, privacy: .public)") }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            Self.log.error("listener not created: \(error, privacy: .public)")
            return
        }

        let browser = NWBrowser(for: .bonjour(type: Self.serviceType, domain: nil), using: Self.parameters(key: key))
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            MainActor.assumeIsolated { self?.browsed(results, myID: me.id) }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    /// Drops every connection; iOS suspends a backgrounded app's sockets anyway.
    func stop() {
        listener?.cancel()
        browser?.cancel()
        listener = nil
        browser = nil
        connections.values.forEach { $0.cancel() }
        connections = [:]
        peerIDs = [:]
        buffers = [:]
        peers = [:]
    }

    /// Sends this device's reading to everyone connected, and to whoever
    /// connects next.
    func broadcast(_ snapshot: BatterySnapshot) {
        guard snapshot != lastSnapshot else { return }
        lastSnapshot = snapshot
        connections.values.forEach(send)
    }

    // MARK: Connections

    private func browsed(_ results: Set<NWBrowser.Result>, myID: String) {
        for result in results {
            guard case .service(let name, _, _, _) = result.endpoint,
                  // Only one side dials, or every pair would connect twice.
                  name > myID,
                  !peerIDs.values.contains(name) else { continue }
            guard let key else { return }
            adopt(NWConnection(to: result.endpoint, using: Self.parameters(key: key)))
        }
    }

    private func adopt(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated { self?.connection(connection, changedTo: state) }
        }
        connection.start(queue: .main)
    }

    private func connection(_ connection: NWConnection, changedTo state: NWConnection.State) {
        switch state {
        case .ready:
            send(to: connection)
            receive(on: connection)
        case .failed(let error):
            // Most likely a handshake with a device on another key: two that
            // both made one before iCloud Keychain synced. Re-read and retry.
            Self.log.info("connection failed: \(error, privacy: .public)")
            drop(connection)
            restartIfKeyChanged()
        case .cancelled:
            drop(connection)
        default:
            break
        }
    }

    private func send(to connection: NWConnection) {
        guard let lastSnapshot else { return }
        let me = SyncDevice.current
        let message = LiveMessage(id: me.id, name: me.name, model: me.model, snapshot: lastSnapshot)
        guard let data = try? LiveMessage.frame(message) else { return }
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                let id = ObjectIdentifier(connection)
                if let data {
                    var buffer = (self.buffers[id] ?? Data()) + data
                    for message in LiveMessage.unframe(&buffer) { self.received(message, on: id) }
                    // A peer that never sends a newline does not get to grow
                    // this without bound.
                    self.buffers[id] = buffer.count > 256 * 1024 ? Data() : buffer
                }
                if isComplete || error != nil {
                    connection.cancel()
                } else {
                    self.receive(on: connection)
                }
            }
        }
    }

    private func received(_ message: LiveMessage, on id: ObjectIdentifier) {
        peerIDs[id] = message.id
        peers[message.id] = SyncedDevice(
            device: SyncDevice(id: message.id, name: message.name, model: message.model),
            date: .now, snapshot: message.snapshot, isLive: true)
    }

    private func drop(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        connections[id] = nil
        buffers[id] = nil
        if let peer = peerIDs.removeValue(forKey: id), !peerIDs.values.contains(peer) {
            peers[peer] = nil
        }
    }

    private func restartIfKeyChanged() {
        guard let fresh = Self.sharedKey(), fresh != key else { return }
        stop()
        start()
    }

    // MARK: Security

    /// TLS 1.2 with a pre-shared key, as in Apple's peer-to-peer sample: no
    /// certificates to manage, and no connection without the key.
    private static func parameters(key: Data) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let psk = HMAC<SHA256>.authenticationCode(for: Data("OpenBattery live link".utf8), using: SymmetricKey(data: key))
        let pskData = Data(psk).withUnsafeBytes { DispatchData(bytes: $0) }
        let identity = Data("OpenBattery".utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(tls.securityProtocolOptions,
                                                pskData as __DispatchData, identity as __DispatchData)
        sec_protocol_options_append_tls_ciphersuite(tls.securityProtocolOptions,
                                                    tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
        let tcp = NWProtocolTCP.Options()
        // Notices a Mac going to sleep or a phone leaving the network within
        // seconds, so its "Live" badge does not outlive it.
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 5
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.includePeerToPeer = true
        return parameters
    }

    /// The key every device on this Apple Account shares, made by whichever
    /// device got there first and synced by iCloud Keychain. Both apps sign
    /// with the same App ID, so they share its default access group.
    private static func sharedKey() -> Data? {
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "cl.franciscosolis.openbattery.live",
            kSecAttrAccount as String: "link-key",
            kSecAttrSynchronizable as String: true,
            kSecUseDataProtectionKeychain as String: true,
        ]
        var result: CFTypeRef?
        let query = item.merging([kSecReturnData as String: true]) { $1 }
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data {
            return data
        }
        let fresh = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let add = item.merging([
            kSecValueData as String: fresh,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]) { $1 }
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            log.error("shared key not saved: \(status)")
            return nil
        }
        return fresh
    }
}

/// One reading on the wire: a line of JSON. JSONEncoder never writes a raw
/// newline, so the newline is a safe delimiter.
struct LiveMessage: Codable, Equatable {
    var id: String
    var name: String
    var model: String
    var snapshot: BatterySnapshot

    static func frame(_ message: LiveMessage) throws -> Data {
        try JSONEncoder().encode(message) + Data([0x0A])
    }

    /// Takes every complete line out of `buffer`, leaving a partial one for
    /// the next read. Lines that do not decode are skipped.
    static func unframe(_ buffer: inout Data) -> [LiveMessage] {
        var messages: [LiveMessage] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer = Data(buffer[buffer.index(after: newline)...])
            if let message = try? JSONDecoder().decode(LiveMessage.self, from: line) { messages.append(message) }
        }
        return messages
    }
}
