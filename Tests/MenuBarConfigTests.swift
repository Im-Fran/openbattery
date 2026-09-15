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

    func testItemsKeepDeclarationOrderRegardlessOfToggleOrder() {
        let config = MenuBarConfig(showsIcon: true, items: [.temperature, .percentage, .batteryWatts])
        XCTAssertEqual(config.items, [.percentage, .batteryWatts, .temperature])
        XCTAssertEqual(config.rawItems, "percentage,batteryWatts,temperature")
    }

    func testRawItemsRoundTripAndIgnoresUnknownValues() {
        let original = MenuBarConfig(showsIcon: false, items: [.percentage, .capacity])
        XCTAssertEqual(MenuBarConfig(showsIcon: false, rawItems: original.rawItems), original)
        XCTAssertEqual(MenuBarConfig(showsIcon: true, rawItems: "percentage,fromTheFuture").items,
                       [.percentage])
    }

    func testTogglingAddsAndRemoves() {
        var config = MenuBarConfig(showsIcon: true, items: [.percentage])
        config = config.toggling(.systemWatts)
        XCTAssertEqual(config.items, [.percentage, .systemWatts])
        config = config.toggling(.percentage)
        XCTAssertEqual(config.items, [.systemWatts])
    }

    func testIconComesBackWhenNothingElseWouldBeVisible() {
        let hidden = MenuBarConfig(showsIcon: false, items: [])
        XCTAssertTrue(hidden.effectiveShowsIcon, "an empty menu bar item could never be clicked again")
        XCTAssertFalse(MenuBarConfig(showsIcon: false, items: [.percentage]).effectiveShowsIcon)
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
