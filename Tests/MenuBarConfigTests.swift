import XCTest

final class MenuBarConfigTests: XCTestCase {

    private func snapshot() -> BatterySnapshot {
        var snapshot = BatterySnapshot()
        snapshot.isPresent = true
        snapshot.percentage = 85
        snapshot.isCharging = true
        snapshot.isPluggedIn = true
        snapshot.timeToFull = 52
        snapshot.batteryWatts = 27.7
        snapshot.systemWatts = 12.0
        snapshot.adapterWatts = 40.1
        snapshot.currentCapacityMAh = 4348
        snapshot.temperature = 34.3
        return snapshot
    }

    func testDefaultsToIconAndPercentage() {
        let config = MenuBarConfig.load(from: UserDefaults(suiteName: "empty-suite")!)
        XCTAssertTrue(config.showsIcon)
        XCTAssertEqual(config.items, [.percentage])
    }

    func testItemsKeepTheUserOrderWithoutDuplicates() {
        let config = MenuBarConfig(showsIcon: true,
                                   items: [.temperature, .percentage, .temperature, .batteryWatts])
        XCTAssertEqual(config.items, [.temperature, .percentage, .batteryWatts])
        XCTAssertEqual(config.rawItems, "temperature,percentage,batteryWatts")
    }

    func testRawItemsRoundTripAndIgnoresUnknownValues() {
        let original = MenuBarConfig(showsIcon: false, items: [.percentage, .capacity])
        XCTAssertEqual(MenuBarConfig(showsIcon: false, rawItems: original.rawItems), original)
        XCTAssertEqual(MenuBarConfig(showsIcon: true, rawItems: "percentage,fromTheFuture").items,
                       [.percentage])
    }

    func testInsertingAddsMovesAndRemoves() {
        var config = MenuBarConfig(showsIcon: true, items: [.percentage])
        config = config.inserting(.systemWatts, before: nil)
        XCTAssertEqual(config.items, [.percentage, .systemWatts])
        config = config.inserting(.temperature, before: .percentage)
        XCTAssertEqual(config.items, [.temperature, .percentage, .systemWatts])
        config = config.inserting(.systemWatts, before: .percentage)
        XCTAssertEqual(config.items, [.temperature, .systemWatts, .percentage])
        XCTAssertEqual(config.inserting(.percentage, before: .percentage), config,
                       "dropping a field onto itself leaves it where it is")
        config = config.removing(.temperature)
        XCTAssertEqual(config.items, [.systemWatts, .percentage])
    }

    func testMovingIsClampedToTheEnds() {
        let config = MenuBarConfig(showsIcon: true, items: [.percentage, .batteryWatts, .temperature])
        XCTAssertEqual(config.moving(.batteryWatts, by: 1).items, [.percentage, .temperature, .batteryWatts])
        XCTAssertEqual(config.moving(.percentage, by: -1), config)
        XCTAssertEqual(config.moving(.temperature, by: 1), config)
        XCTAssertEqual(config.moving(.capacity, by: 1), config)
    }

    func testIconComesBackWhenNothingElseWouldBeVisible() {
        let hidden = MenuBarConfig(showsIcon: false, items: [])
        XCTAssertTrue(hidden.effectiveShowsIcon, "an empty menu bar item could never be clicked again")
        XCTAssertFalse(MenuBarConfig(showsIcon: false, items: [.percentage]).effectiveShowsIcon)
    }

    func testNoBatteryShowsNoPercentageButKeepsTheIcon() {
        let desktop = BatterySnapshot()
        let config = MenuBarConfig(showsIcon: false, items: [.percentage])
        XCTAssertNil(config.text(for: desktop), "a missing battery is not 0%")
        XCTAssertTrue(config.showsIcon(for: desktop))
        XCTAssertFalse(config.showsIcon(for: snapshot()))
    }

    func testOnlySomeFieldsNeedTheExpensiveRead() {
        XCTAssertFalse(MenuBarConfig(showsIcon: true,
                                     items: [.percentage, .timeRemaining, .chargingStatus])
            .needsDetailedRead)
        XCTAssertTrue(MenuBarConfig(showsIcon: true, items: [.percentage, .batteryWatts])
            .needsDetailedRead)
    }

    func testRenderedTextJoinsSelectedFields() {
        let config = MenuBarConfig(showsIcon: true,
                                   items: [.percentage, .batteryWatts, .capacity, .temperature])
        XCTAssertEqual(config.text(for: snapshot()), "85% · +27.7 W · 4,348 mAh · 34.3 °C")
    }

    func testUnavailableFieldsAreSkippedInsteadOfShowingDashes() {
        var unplugged = snapshot()
        unplugged.isPluggedIn = false
        unplugged.isCharging = false
        unplugged.timeToFull = nil
        unplugged.timeToEmpty = nil

        let config = MenuBarConfig(showsIcon: true,
                                   items: [.percentage, .timeRemaining, .adapterWatts])
        XCTAssertEqual(config.text(for: unplugged), "85%")
        XCTAssertNil(MenuBarConfig(showsIcon: true, items: [.adapterWatts]).text(for: unplugged))
    }

    func testChargingStatusStaysShort() {
        XCTAssertEqual(snapshot().shortStatusText, "Charging")
        var idle = snapshot()
        idle.isCharging = false
        idle.isPluggedIn = false
        XCTAssertEqual(idle.shortStatusText, "Battery")
    }
}
