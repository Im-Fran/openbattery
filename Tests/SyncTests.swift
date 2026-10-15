import SwiftData
import XCTest

/// The iCloud sync: what travels, what gets recorded, and what a device list shows.
@MainActor
final class SyncTests: XCTestCase {

    private let mac = SyncDevice(id: "mac", name: "MacBook", model: "Mac15,7")
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func snap(_ percentage: Int, charging: Bool = false, plugged: Bool = false) -> BatterySnapshot {
        var s = BatterySnapshot()
        s.percentage = percentage
        s.isCharging = charging
        s.isPluggedIn = plugged
        s.isPresent = true
        return s
    }

    // MARK: Payload

    func testSnapshotSurvivesTheRecord() {
        var s = snap(73, charging: true, plugged: true)
        s.manufactureDate = Date(timeIntervalSince1970: 1_650_000_000.25)
        s.cycleCount = 412
        s.adapterDescription = "96W USB-C"
        s.lifetime = .init(averageTemperature: 29.5, maximumChargeCurrentMA: 4100, operatingTimeRaw: 12_345)

        let record = BatteryRecord(device: mac, snapshot: s, date: t0)
        XCTAssertEqual(record.snapshot, s)
        XCTAssertEqual(record.percentage, 73)
        XCTAssertEqual(record.device, mac)
    }

    // MARK: Synced data

    func testSummariesCountEachDeviceAndKeepItsLatestName() {
        let renamed = SyncDevice(id: "mac", name: "Work Mac", model: "Mac15,7")
        let phone = SyncDevice(id: "phone", name: "iPhone", model: "iPhone17,1")
        let records = [
            BatteryRecord(device: mac, snapshot: snap(50), date: t0),
            BatteryRecord(device: phone, snapshot: snap(90), date: t0.addingTimeInterval(60)),
            BatteryRecord(device: renamed, snapshot: snap(40), date: t0.addingTimeInterval(120)),
        ]
        let summaries = SyncedHistory.summaries(from: records)
        XCTAssertEqual(summaries.map(\.id), ["mac", "phone"])
        XCTAssertEqual(summaries[0].device.name, "Work Mac")
        XCTAssertEqual(summaries[0].count, 2)
        XCTAssertEqual(summaries[0].oldest, t0)
        XCTAssertEqual(summaries[0].newest, t0.addingTimeInterval(120))
    }

    // MARK: Live link

    func testLiveMessagesSurviveSplitReads() throws {
        let one = LiveMessage(id: "mac", name: "MacBook", model: "Mac15,7", snapshot: snap(40))
        let two = LiveMessage(id: "phone", name: "iPhone", model: "iPhone17,1", snapshot: snap(90, charging: true))
        let wire = try LiveMessage.frame(one) + LiveMessage.frame(two)
        let cut = wire.count - 5

        var buffer = Data(wire.prefix(cut))
        XCTAssertEqual(LiveMessage.unframe(&buffer), [one])
        buffer += wire.suffix(from: cut)
        XCTAssertEqual(LiveMessage.unframe(&buffer), [two])
        XCTAssertTrue(buffer.isEmpty)

        var garbage = Data("not json\n".utf8)
        XCTAssertEqual(LiveMessage.unframe(&garbage), [])
    }

    func testLiveReadingsReplaceSyncedOnes() {
        let phone = SyncDevice(id: "phone", name: "iPhone", model: "iPhone17,1")
        let synced = [SyncedDevice(device: mac, date: t0, snapshot: snap(50)),
                      SyncedDevice(device: phone, date: t0, snapshot: snap(80))]
        let live = [SyncedDevice(device: mac, date: t0.addingTimeInterval(600), snapshot: snap(45), isLive: true),
                    SyncedDevice(device: SyncDevice(id: "new", name: "iPad", model: "iPad16,3"),
                                 date: t0, snapshot: snap(70), isLive: true)]
        let result = SyncedDevice.overlaying(live, on: synced)
        XCTAssertEqual(result.map(\.id), ["new", "mac", "phone"])
        XCTAssertEqual(result.first { $0.id == "mac" }?.snapshot.percentage, 45)
        XCTAssertEqual(result.map(\.isLive), [true, true, false])
    }

    // MARK: Relayed power and health

    func testListedKeepsTheMacsReadingBesideThePhonesOwn() {
        var health = snap(40, charging: true, plugged: true)
        health.cycleCount = 312
        health.volts = 4.1
        let phone = SyncDevice(id: "phone", name: "iPhone", model: "iPhone17,1")
        let records = [
            BatteryRecord(device: phone, snapshot: snap(60), date: t0.addingTimeInterval(600)),
            BatteryRecord(device: SyncDevice(id: "phone", name: "iPhone", model: "iPhone17,1", relayedBy: "MacBook"),
                          snapshot: health, date: t0),
        ]
        let listed = SyncedDevice.listed(records: records, live: [], liveRelayed: [:])
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed[0].relayedReading?.mac, "MacBook")
        // Power and health from the Mac, charge from the phone's newer record.
        let combined = listed[0].combinedSnapshot
        XCTAssertEqual(combined.volts, 4.1)
        XCTAssertEqual(combined.cycleCount, 312)
        XCTAssertEqual(combined.percentage, 60)
        XCTAssertFalse(combined.isCharging)

        // A Mac nearby that just read it wins over the older one in iCloud.
        var fresher = health
        fresher.volts = 4.3
        let live = RelayedReading(mac: "Studio", date: t0.addingTimeInterval(900), snapshot: fresher)
        let relisted = SyncedDevice.listed(records: records, live: [], liveRelayed: ["phone": live])
        XCTAssertEqual(relisted[0].relayedReading?.mac, "Studio")
        XCTAssertEqual(relisted[0].combinedSnapshot.volts, 4.3)
    }

    func testRelayedReadingGoesStaleAfterFiveMinutes() {
        let reading = RelayedReading(mac: "MacBook", date: t0, snapshot: snap(50))
        XCTAssertFalse(reading.isStale(at: t0.addingTimeInterval(RelayedReading.freshness)))
        XCTAssertTrue(reading.isStale(at: t0.addingTimeInterval(RelayedReading.freshness + 1)))
    }

    /// A build from before relayed readings and read requests still talks to
    /// this one.
    func testLiveMessageFromAnOlderBuildStillDecodes() throws {
        let old = LiveMessage(id: "mac", name: "MacBook", model: "Mac15,7", snapshot: snap(40))
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as! [String: Any]
        json["relayed"] = nil
        json["wantsReading"] = nil
        var buffer = try JSONSerialization.data(withJSONObject: json) + Data([0x0A])
        XCTAssertEqual(LiveMessage.unframe(&buffer), [old])
    }

    // MARK: Widgets

    func testWidgetListsThisDeviceFirstThenByName() {
        let devices = [
            SyncedDevice(device: SyncDevice(id: "z", name: "Zeta Mac", model: "Mac15,7"), date: t0, snapshot: snap(10)),
            SyncedDevice(device: SyncDevice(id: "me", name: "iPhone", model: "iPhone17,1"), date: t0,
                         snapshot: snap(76, charging: true, plugged: true)),
            SyncedDevice(device: SyncDevice(id: "a", name: "air", model: "Mac15,7"), date: t0, snapshot: snap(50)),
        ]
        let entries = WidgetFeed.entries(devices, currentID: "me")
        XCTAssertEqual(entries.map(\.id), ["me", "a", "z"])
        XCTAssertEqual(entries[0].symbol, "iphone")
        XCTAssertTrue(entries[0].isCharging && entries[0].isCurrent)
    }

    // MARK: Device list

    func testLatestKeepsTheNewestPerDeviceNewestFirst() {
        let phone = SyncDevice(id: "phone", name: "iPhone", model: "iPhone17,1")
        let records = [
            BatteryRecord(device: mac, snapshot: snap(50), date: t0),
            BatteryRecord(device: phone, snapshot: snap(90), date: t0.addingTimeInterval(60)),
            BatteryRecord(device: mac, snapshot: snap(40), date: t0.addingTimeInterval(120)),
            BatteryRecord(device: phone, snapshot: snap(80), date: t0.addingTimeInterval(30)),
        ]
        let latest = SyncedDevice.latest(from: records)
        XCTAssertEqual(latest.map(\.id), ["mac", "phone"])
        XCTAssertEqual(latest.map(\.snapshot.percentage), [40, 90])
    }

    /// A payload this build cannot read falls back to the reading before it.
    func testLatestSkipsAnUndecodablePayload() {
        let broken = BatteryRecord(device: mac, snapshot: snap(10), date: t0.addingTimeInterval(60))
        broken.payload = Data("not json".utf8)
        let latest = SyncedDevice.latest(from: [broken, BatteryRecord(device: mac, snapshot: snap(55), date: t0)])
        XCTAssertEqual(latest.map(\.snapshot.percentage), [55])
    }

    func testRelayedMatchesOnModelOnlyWhenAMacReadIt() {
        let phone = SyncDevice(id: "a", name: "iPhone", model: "iPhone17,1")
        let own = SyncedDevice(device: phone, date: t0, snapshot: snap(60))
        let relayed = SyncedDevice(device: SyncDevice(id: "udid", name: "iPhone", model: "iPhone17,1", relayedBy: "mac"),
                                   date: t0, snapshot: snap(60))
        XCTAssertEqual(SyncedDevice.relayed(for: phone, in: [own, relayed])?.id, "udid")
        XCTAssertNil(SyncedDevice.relayed(for: phone, in: [own]))
        let other = SyncDevice(id: "b", name: "iPhone", model: "iPhone16,2")
        XCTAssertNil(SyncedDevice.relayed(for: other, in: [relayed]))
    }

    /// Once a Mac knows the phone's own ID, its reading is filed under it: the
    /// two share an ID, list once, and the ID wins over a same-model stranger.
    func testRelayedUnderThePhonesOwnIDListsOnce() {
        var health = snap(40)
        health.cycleCount = 312
        let phone = SyncDevice(id: "phone", name: "iPhone", model: "iPhone17,1")
        let stranger = BatteryRecord(device: SyncDevice(id: "x", name: "Other", model: "iPhone17,1", relayedBy: "mac"),
                                     snapshot: snap(10), date: t0.addingTimeInterval(120))
        let records = [
            BatteryRecord(device: phone, snapshot: snap(60), date: t0.addingTimeInterval(60)),
            BatteryRecord(device: SyncDevice(id: "phone", name: "iPhone", model: "iPhone17,1", relayedBy: "mac"),
                          snapshot: health, date: t0),
            stranger,
        ]
        let latest = SyncedDevice.latest(from: records)
        XCTAssertEqual(latest.count, 3)
        XCTAssertEqual(SyncedDevice.relayed(for: phone, in: latest)?.snapshot.cycleCount, 312)

        let merged = SyncedDevice.merged(latest)
        XCTAssertEqual(merged.map(\.id), ["x", "phone"])
        XCTAssertEqual(merged[1].snapshot.percentage, 60)
        XCTAssertEqual(merged[1].snapshot.cycleCount, 312)
    }

    func testRelayedIDHidesTheUDID() {
        let id = SyncDevice.relayedID(udid: "00008140-001A006A02E3001C")
        XCTAssertEqual(id.count, 32)
        XCTAssertFalse(id.contains("00008140"))
        XCTAssertEqual(id, SyncDevice.relayedID(udid: "00008140-001A006A02E3001C"))
    }

    /// The phone's own entry stays and borrows the health only a Mac can read.
    func testMergedFoldsTheRelayedReadingIntoThePhone() {
        var health = snap(40)
        health.cycleCount = 312
        health.designCapacityMAh = 3500
        let own = SyncedDevice(device: SyncDevice(id: "a", name: "iPhone", model: "iPhone17,1"),
                               date: t0, snapshot: snap(60))
        let relayed = SyncedDevice(device: SyncDevice(id: "udid", name: "iPhone", model: "iPhone17,1", relayedBy: "mac"),
                                   date: t0, snapshot: health)
        let macEntry = SyncedDevice(device: mac, date: t0, snapshot: snap(80))
        let merged = SyncedDevice.merged([own, relayed, macEntry])
        XCTAssertEqual(merged.map(\.id), ["a", "mac"])
        XCTAssertEqual(merged[0].snapshot.percentage, 60)
        XCTAssertEqual(merged[0].snapshot.cycleCount, 312)
        XCTAssertEqual(merged[0].snapshot.designCapacityMAh, 3500)
        // Nothing to fold into: the relayed reading is the only one there is.
        XCTAssertEqual(SyncedDevice.merged([relayed]).map(\.id), ["udid"])
    }

    // MARK: When to record

    func testShouldRecord() {
        let previous = (date: t0, snapshot: snap(50))
        let soon = t0.addingTimeInterval(60)
        func record(_ s: BatterySnapshot, at now: Date) -> Bool {
            CloudStore.shouldRecord(s, previous: previous, now: now)
        }
        XCTAssertTrue(CloudStore.shouldRecord(snap(50), previous: nil, now: t0), "first reading")
        XCTAssertFalse(record(snap(48), at: soon), "small change within spacing")
        XCTAssertTrue(record(snap(50), at: t0.addingTimeInterval(CloudStore.minimumSpacing)), "spacing elapsed")
        XCTAssertTrue(record(snap(50, charging: true), at: soon), "charging flip")
        XCTAssertTrue(record(snap(50, plugged: true), at: soon), "plug flip")
        XCTAssertTrue(record(snap(45), at: soon), "5 % jump")
        XCTAssertTrue(record(snap(55), at: soon), "5 % jump up")
    }

    func testPublishInsertsOnceThenRateLimits() throws {
        let store = CloudStore(inMemory: true)
        store.publish(snap(50), for: mac, at: t0)
        store.publish(snap(49), for: mac, at: t0.addingTimeInterval(60))
        XCTAssertEqual(try store.container.mainContext.fetchCount(FetchDescriptor<BatteryRecord>()), 1)

        store.publish(snap(49), for: mac, at: t0.addingTimeInterval(CloudStore.minimumSpacing))
        XCTAssertEqual(try store.container.mainContext.fetchCount(FetchDescriptor<BatteryRecord>()), 2)
    }

    func testForcePublishSkipsSpacingAndDeleteClearsOneDevice() throws {
        let store = CloudStore(inMemory: true)
        let phone = SyncDevice(id: "phone", name: "iPhone", model: "iPhone17,1")
        store.publish(snap(50), for: mac, at: t0)
        store.publish(snap(50), for: mac, at: t0.addingTimeInterval(60), force: true)
        store.publish(snap(90), for: phone, at: t0)
        let context = store.container.mainContext
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<BatteryRecord>()), 3)

        try store.deleteHistory(of: mac.id)
        XCTAssertEqual(try context.fetch(FetchDescriptor<BatteryRecord>()).map(\.deviceID), ["phone"])
    }

    func testPublishIgnoresAMissingBattery() throws {
        let store = CloudStore(inMemory: true)
        var desktop = snap(0)
        desktop.isPresent = false
        store.publish(desktop, for: mac, at: t0)
        XCTAssertEqual(try store.container.mainContext.fetchCount(FetchDescriptor<BatteryRecord>()), 0)
    }

    /// The test bundle has no iCloud entitlement, like a Debug build: the
    /// `.automatic` store CloudStore opens must still open and save, locally.
    func testAutomaticCloudKitFallsBackToLocalWithoutEntitlement() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("store")
        defer { try? FileManager.default.removeItem(at: url) }
        let schema = Schema([BatteryRecord.self])
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(
            schema: schema, url: url, cloudKitDatabase: .automatic))
        container.mainContext.insert(BatteryRecord(device: mac, snapshot: snap(50), date: t0))
        try container.mainContext.save()
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<BatteryRecord>()), 1)
    }
}
