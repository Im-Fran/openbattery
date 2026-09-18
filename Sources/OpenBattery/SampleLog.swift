import Foundation

/// A short, self-recorded log of one battery reading over time.
///
/// The gas gauge keeps no history, so the only history that exists is the one
/// we write down. Two of them do: the charge every few minutes for half a day,
/// and the full charge capacity once a day for a year. Both are small enough
/// to live in `UserDefaults` — the charge log is under 150 rows — so there is
/// no file to create and nothing to migrate.
///
/// Gaps are expected and honest: nothing is recorded while the Mac sleeps or
/// the app is not running, and the charts leave those buckets empty rather
/// than inventing a value.
struct SampleLog: Equatable {

    struct Sample: Codable, Equatable {
        let date: Date
        let value: Int
    }

    /// One bar of a chart: the last reading taken in that hour or month.
    struct Bucket: Identifiable, Equatable {
        let date: Date
        let value: Int?

        var id: Date { date }
    }

    let key: String
    /// What one bar covers, and therefore how far back the log is kept.
    let unit: Calendar.Component
    let buckets: Int
    /// Readings that arrive sooner than this after the last one are dropped.
    let minimumSpacing: TimeInterval
    private(set) var samples: [Sample] = []

    /// Charge in percent: twelve hours of it.
    static let charge = SampleLog(key: "chargeHistory", unit: .hour, buckets: 12,
                                  minimumSpacing: 5 * 60)

    /// Full charge capacity in mAh: twelve months of it. It moves by a handful
    /// of mAh a week at most, so one reading a day is already generous.
    static let capacity = SampleLog(key: "capacityHistory", unit: .month, buckets: 12,
                                    minimumSpacing: 24 * 3600)

    func loaded(from defaults: UserDefaults = .standard, now: Date = .now,
                calendar: Calendar = .current) -> SampleLog {
        guard let data = defaults.data(forKey: key),
              let stored = try? JSONDecoder().decode([Sample].self, from: data)
        else { return self }
        var log = self
        log.samples = trimmed(stored, now: now, calendar: calendar)
        return log
    }

    /// Appends `value`, unless the previous sample is too recent to be worth
    /// another row. Returns whether anything changed, so a caller can skip
    /// both the save and the redraw.
    @discardableResult
    mutating func record(_ value: Int, at date: Date = .now,
                         to defaults: UserDefaults? = .standard,
                         calendar: Calendar = .current) -> Bool {
        // A clock that moved backwards (time zone, NTP, a manual change) would
        // otherwise leave samples in the future that never expire.
        var fresh = samples.filter { $0.date <= date }
        let keptEverything = fresh.count == samples.count
        if keptEverything, let last = fresh.last,
           date.timeIntervalSince(last.date) < minimumSpacing {
            return false
        }
        fresh.append(Sample(date: date, value: value))
        let updated = trimmed(fresh, now: date, calendar: calendar)
        guard updated != samples else { return false }
        samples = updated
        if let defaults, let data = try? JSONEncoder().encode(samples) {
            defaults.set(data, forKey: key)
        }
        return true
    }

    /// One bucket per bar, oldest first. A `nil` value is a bucket we have
    /// nothing for, not a reading of zero.
    func bucketed(now: Date = .now, calendar: Calendar = .current) -> [Bucket] {
        (0..<buckets).reversed().compactMap { offset in
            guard let start = start(offset, now: now, calendar: calendar),
                  let end = calendar.date(byAdding: unit, value: 1, to: start)
            else { return nil }
            return Bucket(date: start,
                          value: samples.last { $0.date >= start && $0.date < end }?.value)
        }
    }

    /// The start of the bucket `offset` units before the one holding `now`.
    private func start(_ offset: Int, now: Date, calendar: Calendar) -> Date? {
        let current = calendar.dateInterval(of: unit, for: now)?.start ?? now
        return calendar.date(byAdding: unit, value: -offset, to: current)
    }

    /// Anything older than the oldest bucket can never be drawn again.
    private func trimmed(_ samples: [Sample], now: Date, calendar: Calendar) -> [Sample] {
        let oldest = start(buckets - 1, now: now, calendar: calendar) ?? now
        return samples.filter { $0.date >= oldest && $0.date <= now }.sorted { $0.date < $1.date }
    }
}
