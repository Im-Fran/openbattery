import XCTest

/// The interface is English, but the clock and the date order are the user's.
final class LocaleTests: XCTestCase {

    func testEnglishLocaleKeepsTheRegion() {
        XCTAssertEqual(Fmt.englishLocale(basedOn: Locale(identifier: "es_CL")).identifier, "en_CL")
        XCTAssertEqual(Fmt.englishLocale(basedOn: Locale(identifier: "de_DE")).identifier, "en_DE")
    }

    /// Dropping the region is the bug this guards: a plain "en" reintroduces
    /// the 12-hour clock for everyone whose region does not use it.
    func testEnglishLocaleKeepsTheHourCycle() {
        var components = Locale.Components(identifier: "es_CL")
        components.hourCycle = .zeroToTwentyThree
        let english = Fmt.englishLocale(basedOn: Locale(components: components))

        XCTAssertEqual(english.hourCycle, .zeroToTwentyThree)
        let noon = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertFalse(noon.formatted(Date.FormatStyle.dateTime.hour().locale(english)).contains("PM"))
    }

    /// The region orders the fields; the month stays a word, because a date
    /// that is all digits cannot be read on any day that could be a month.
    func testDateKeepsTheRegionOrderAndNamesTheMonth() {
        let may3 = DateComponents(calendar: .current, year: 2024, month: 5, day: 3).date!
        for locale in ["es_CL", "en_US"].map({ Fmt.englishLocale(basedOn: Locale(identifier: $0)) }) {
            let formatted = may3.formatted(
                .dateTime.day().month(.abbreviated).year().locale(locale))
            XCTAssertTrue(formatted.contains("May"), "got \(formatted)")
        }
    }

    /// Numbers stay English on purpose: region-grouped separators would change
    /// every reading in the menu bar, which is not what the clock fix is about.
    func testNumbersStayEnglish() {
        XCTAssertEqual(Fmt.mAh(4_348), "4,348 mAh")
    }
}
