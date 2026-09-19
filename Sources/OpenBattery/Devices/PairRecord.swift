import Foundation

/// The credentials a lockdown session needs, as macOS already holds them.
///
/// We do not pair the device ourselves and we never ask for Full Disk Access:
/// `usbmuxd` reads /var/db/lockdown on our behalf and hands the record over
/// (`ReadPairRecord`). A device trusted in Finder is therefore a device
/// OpenBattery can read, and one that has never been trusted stays unreadable
/// until its owner taps Trust — which is exactly the right gate.
struct PairRecord: Equatable {
    /// The pair the TLS session presents. The host pair, not the root one: with
    /// the root certificate the device drops the connection mid-handshake.
    let hostCertificatePEM: String
    let hostKeyPEM: String
    let hostID: String
    let systemBUID: String

    init?(plist record: [String: Any]) {
        func text(_ key: String) -> String? {
            if let data = record[key] as? Data { return String(data: data, encoding: .utf8) }
            return record[key] as? String
        }
        guard let certificate = text("HostCertificate"), let key = text("HostPrivateKey"),
              let hostID = record["HostID"] as? String,
              let systemBUID = record["SystemBUID"] as? String else { return nil }
        hostCertificatePEM = certificate
        hostKeyPEM = key
        self.hostID = hostID
        self.systemBUID = systemBUID
    }
}
