import Charts
import SwiftData
import SwiftUI

/// One device: its latest reading and the charge history behind it. Sections
/// appear only for what the reading carries — a Mac reports watts and health,
/// an iPhone recording itself reports little more than its percentage.
struct DeviceDetailView: View {
    @Query private var records: [BatteryRecord]
    @State private var period: Period = .day

    init(deviceID: String) {
        _records = Query(filter: #Predicate<BatteryRecord> { $0.deviceID == deviceID },
                         sort: \BatteryRecord.date)
    }

    var body: some View {
        if let latest = records.last, let snapshot = latest.snapshot {
            content(latest, snapshot)
        } else {
            ContentUnavailableView("No Readings", systemImage: "battery.0percent",
                                   description: Text("This device has not recorded a reading yet."))
        }
    }

    private func content(_ latest: BatteryRecord, _ snapshot: BatterySnapshot) -> some View {
        List {
            Section { Hero(snapshot: snapshot, date: latest.date) }

            Section {
                Picker("Period", selection: $period) {
                    ForEach(Period.allCases, id: \.self) { Text($0.title) }
                }
                .pickerStyle(.segmented)
                .listRowSeparator(.hidden)
                // A fresh chart per period: animating between the two domains
                // left the y-axis labels stuck half faded out.
                ChargeChart(records: records, period: period).id(period)
            } header: {
                Text("Charge History")
            }

            let power = powerRows(snapshot)
            if !power.isEmpty {
                Section("Power") { rows(power) }
            }
            let health = healthRows(snapshot)
            if !health.isEmpty {
                Section("Health") { rows(health) }
            }

            Section {
                value("Model Identifier", latest.deviceModel)
            } footer: {
                Text(footer(latest))
            }
        }
        .navigationTitle(latest.deviceName)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func footer(_ record: BatteryRecord) -> String {
        let when = "Last updated \(record.date.formatted(.dateTime.day().month(.abbreviated).hour().minute().locale(Fmt.dateLocale)))"
        return record.relayedBy.map { "\(when) · Read by \($0)" } ?? when
    }

    private func rows(_ items: [(String, String)]) -> some View {
        ForEach(items, id: \.0) { value($0.0, $0.1) }
    }

    /// `LabeledContent(_:value:)` draws the value in `.secondary`, under the
    /// contrast a reading needs.
    private func value(_ title: String, _ value: String) -> some View {
        LabeledContent(title) {
            Text(value)
                .foregroundStyle(.subdued)
                .accessibilityLabel(Fmt.spoken(value))
        }
    }

    /// Only the fields the reading has: an em dash on a row that can never be
    /// filled in (an iPhone has no adapter watts to report) is noise.
    private func powerRows(_ s: BatterySnapshot) -> [(String, String)] {
        [
            ("Battery", s.batteryWatts.map { Fmt.watts($0, signed: true) }),
            ("System", s.systemWatts.map { Fmt.watts($0) }),
            ("Adapter Output", s.adapterWatts.map { Fmt.watts($0) }),
            ("Adapter Rating", s.adapterRatedWatts.map { "\($0) W" }),
            ("Voltage", s.volts.map { Fmt.volts($0) }),
            ("Current", s.amps.map { Fmt.amps($0) }),
            ("Adapter", s.adapterDescription),
        ].compactMap { label, value in value.map { (label, $0) } }
    }

    private func healthRows(_ s: BatterySnapshot) -> [(String, String)] {
        [
            ("Maximum Capacity", s.healthPercent.map { Fmt.percent($0) }),
            ("Cycle Count", s.cycleCount.map { Fmt.integer($0) }),
            ("Full Charge Capacity", s.fullChargeCapacityMAh.map { Fmt.mAh($0) }),
            ("Design Capacity", s.designCapacityMAh.map { Fmt.mAh($0) }),
            ("Temperature", s.temperature.map { Fmt.celsius($0) }),
        ].compactMap { label, value in value.map { (label, $0) } }
    }
}

private enum Period: CaseIterable {
    case day, week

    var title: String { self == .day ? "24 Hours" : "7 Days" }
    var spoken: String { self == .day ? "last 24 hours" : "last 7 days" }
    var duration: TimeInterval { self == .day ? 24 * 3600 : 7 * 24 * 3600 }
}

private struct Hero: View {
    let snapshot: BatterySnapshot
    let date: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(snapshot.percentage)%")
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    .monospacedDigit()
                Spacer()
                Image(systemName: snapshot.batterySymbol)
                    .font(.title)
                    .foregroundStyle(snapshot.chargeTint)
            }
            ProgressView(value: Double(snapshot.percentage), total: 100)
                .tint(snapshot.heroTint)
            Text(statusText)
                .font(.headline)
            if snapshot.lowPowerMode {
                Label("Low Power Mode", systemImage: "leaf.fill")
                    .font(.subheadline)
                    .foregroundStyle(.subdued)
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Charge")
        .accessibilityValue("\(snapshot.percentage) percent, \(statusText)\(snapshot.lowPowerMode ? ", Low Power Mode" : "")")
    }

    /// A "2:10 left" estimate is only true when it was taken: from an older
    /// reading the time-free wording is the honest one.
    private var statusText: String {
        Date.now.timeIntervalSince(date) < 15 * 60 ? snapshot.statusText : snapshot.listStatus
    }
}

/// Charge over the chosen period, with the line broken wherever no reading
/// was taken — a Mac asleep overnight is a gap, not a straight ramp.
private struct ChargeChart: View {
    let records: [BatteryRecord]
    let period: Period

    @State private var pointer: Date?
    @ScaledMetric(relativeTo: .body) private var chartHeight: CGFloat = 180

    /// Readings further apart than this are drawn as separate runs.
    private static let gap: TimeInterval = 3600

    struct Point: Identifiable {
        let date: Date
        let percentage: Int
        let run: Int
        var id: Date { date }
    }

    private var span: ClosedRange<Date> {
        Date.now.addingTimeInterval(-period.duration)...Date.now
    }

    private var points: [Point] {
        var run = 0
        var previous: Date?
        return records.filter { span.contains($0.date) }.map { record in
            if let previous, record.date.timeIntervalSince(previous) > Self.gap { run += 1 }
            previous = record.date
            return Point(date: record.date, percentage: record.percentage, run: run)
        }
    }

    var body: some View {
        let points = points
        if points.isEmpty {
            Text("No readings in the \(period.spoken).")
                .font(.callout)
                .foregroundStyle(.subdued)
                .frame(maxWidth: .infinity, minHeight: chartHeight)
        } else {
            chart(points)
        }
    }

    private func chart(_ points: [Point]) -> some View {
        let lone = Set(Dictionary(grouping: points, by: \.run).filter { $0.value.count == 1 }.keys)
        let selected = pointer.flatMap { pointer in
            points.min { abs($0.date.timeIntervalSince(pointer)) < abs($1.date.timeIntervalSince(pointer)) }
        }
        return Chart {
            ForEach(points) { point in
                LineMark(x: .value("Time", point.date), y: .value("Charge", point.percentage),
                         series: .value("Run", point.run))
                    .foregroundStyle(Color.accentColor)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                // A run of one reading has no line to draw; a dot keeps it.
                if lone.contains(point.run) {
                    PointMark(x: .value("Time", point.date), y: .value("Charge", point.percentage))
                        .foregroundStyle(Color.accentColor)
                        .symbolSize(24)
                }
            }
            if let selected {
                RuleMark(x: .value("Time", selected.date))
                    .foregroundStyle(Color.primary.opacity(0.55))
                    .annotation(position: .top, spacing: 4,
                                overflowResolution: .init(x: .fit(to: .plot), y: .fit(to: .plot))) {
                        Text("\(selected.date.formatted(readoutFormat)) · \(selected.percentage)%")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.background))
                            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.separator))
                    }
            }
        }
        // The period the picker promises, not the period that holds data, and
        // a full 0–100 scale so a 5% dip does not look like a cliff.
        .chartXScale(domain: span)
        .chartYScale(domain: 0...100)
        .chartXSelection(value: $pointer)
        .chartYAxis {
            AxisMarks(values: [0, 50, 100]) { value in
                AxisGridLine()
                AxisValueLabel { if let number = value.as(Int.self) { Text("\(number)%") } }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: period == .day ? .hour : .day, count: period == .day ? 6 : 1)) { _ in
                AxisGridLine()
                AxisValueLabel(format: axisFormat)
            }
        }
        .frame(height: chartHeight)
        .padding(.vertical, 8)
        // Hundreds of points are too many to swipe through one by one: the
        // descriptor gives VoiceOver a summary and Audio Graph instead.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Charge history, \(period.spoken)")
        .accessibilityValue(ChargeDescriptor(points: points, span: span, period: period).summary)
        .accessibilityChartDescriptor(ChargeDescriptor(points: points, span: span, period: period))
    }

    private var axisFormat: Date.FormatStyle {
        (period == .day ? Date.FormatStyle.dateTime.hour() : .dateTime.weekday(.abbreviated))
            .locale(Fmt.dateLocale)
    }

    private var readoutFormat: Date.FormatStyle {
        (period == .day ? Date.FormatStyle.dateTime.hour().minute()
                        : .dateTime.weekday(.abbreviated).hour().minute())
            .locale(Fmt.dateLocale)
    }
}

private struct ChargeDescriptor: AXChartDescriptorRepresentable {
    let points: [ChargeChart.Point]
    let span: ClosedRange<Date>
    let period: Period

    var summary: String {
        let values = points.map(\.percentage)
        guard let low = values.min(), let high = values.max(), let last = values.last else {
            return "No readings"
        }
        return "Between \(low) and \(high) percent, \(last) percent at the latest reading"
    }

    func makeChartDescriptor() -> AXChartDescriptor {
        let format = Date.FormatStyle.dateTime.weekday(.wide).hour().minute().locale(Fmt.dateLocale)
        let x = AXNumericDataAxisDescriptor(
            title: "Time",
            range: span.lowerBound.timeIntervalSince1970...span.upperBound.timeIntervalSince1970,
            gridlinePositions: []
        ) { Date(timeIntervalSince1970: $0).formatted(format) }
        let y = AXNumericDataAxisDescriptor(title: "Charge", range: 0...100, gridlinePositions: [0, 50, 100]) {
            "\(Int($0)) percent"
        }
        // One series per run, so Audio Graph falls silent across a gap too.
        let series = Dictionary(grouping: points, by: \.run).sorted { $0.key < $1.key }.map { _, run in
            AXDataSeriesDescriptor(name: "Charge", isContinuous: true, dataPoints: run.map {
                AXDataPoint(x: $0.date.timeIntervalSince1970, y: Double($0.percentage))
            })
        }
        return AXChartDescriptor(title: "Charge history, \(period.spoken)", summary: summary,
                                 xAxis: x, yAxis: y, additionalAxes: [], series: series)
    }
}
