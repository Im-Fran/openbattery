import XCTest

final class SampleLogTests: XCTestCase {

    /// 22:00:00 UTC, on the hour, so the hourly buckets are predictable.
    private let start = Date(timeIntervalSince1970: 1_699_999_200)

    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// `nil` defaults: these tests exercise the rules, not `UserDefaults`.
    private func charge(_ samples: [(minutes: Double, value: Int)]) -> SampleLog {
        var log = SampleLog.charge
        for sample in samples {
            log.record(sample.value, at: start.addingTimeInterval(sample.minutes * 60),
                       to: nil, calendar: calendar)
        }
        return log
    }

    func testRecordsAtMostOneSamplePerMinimumSpacing() {
        XCTAssertEqual(charge([(0, 50), (2, 51), (4, 52), (6, 53)]).samples.map(\.value), [50, 53])
    }

    func testDropsSamplesOlderThanTheOldestBucket() {
        var log = charge([(0, 90), (60, 80)])
        // 11:00 the next day: the oldest hourly bucket starts at midnight.
        log.record(70, at: start.addingTimeInterval(13 * 3600), to: nil, calendar: calendar)
        XCTAssertEqual(log.samples.map(\.value), [70])
    }

    /// A clock that jumped backwards must not leave unreachable future samples.
    func testRecordingInThePastDiscardsLaterSamples() {
        var log = charge([(0, 90), (60, 80)])
        log.record(70, at: start.addingTimeInterval(30 * 60), to: nil, calendar: calendar)
        XCTAssertEqual(log.samples.map(\.value), [90, 70])
    }

    func testBucketsTakeTheLastReadingOfEachHourAndLeaveGapsEmpty() {
        //       22:00   22:30   23:05   01:05             now: 01:30
        let log = charge([(0, 90), (30, 85), (65, 80), (185, 60)])
        let buckets = log.bucketed(now: start.addingTimeInterval(210 * 60), calendar: calendar)

        XCTAssertEqual(buckets.count, SampleLog.charge.buckets)
        XCTAssertEqual(buckets.compactMap(\.value), [85, 80, 60])
        // Oldest first, so the last four buckets are 22:00, 23:00, 00:00, 01:00.
        XCTAssertNil(buckets[buckets.count - 2].value, "nothing was recorded at midnight")
    }

    /// The capacity log buckets by month and keeps a year, on the same code.
    func testCapacityLogBucketsByMonth() {
        var log = SampleLog.capacity
        let day: TimeInterval = 24 * 3600
        log.record(5_300, at: start, to: nil, calendar: calendar)
        log.record(5_290, at: start.addingTimeInterval(40 * day), to: nil, calendar: calendar)
        let buckets = log.bucketed(now: start.addingTimeInterval(40 * day), calendar: calendar)

        XCTAssertEqual(buckets.count, 12)
        XCTAssertEqual(buckets.compactMap(\.value), [5_300, 5_290])
        XCTAssertEqual(buckets.last?.value, 5_290, "the newest month is the last bar")
    }

    func testPersistsThroughUserDefaults() {
        let defaults = UserDefaults(suiteName: "sample-log-test")!
        defaults.removeObject(forKey: SampleLog.charge.key)
        var log = SampleLog.charge
        log.record(77, at: .now, to: defaults)

        XCTAssertEqual(SampleLog.charge.loaded(from: defaults).samples.map(\.value), [77])
        defaults.removeObject(forKey: SampleLog.charge.key)
    }
}
