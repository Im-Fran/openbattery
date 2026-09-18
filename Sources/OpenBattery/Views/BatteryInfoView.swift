import Charts
import SwiftUI

/// Everything the gas gauge will tell us, a tab per group of readings.
///
/// Every tab is built the same way — one headline reading, three numbers
/// beside it, and the history or breakdown underneath — so moving between
/// them never asks anyone to learn a new layout.
struct BatteryInfoView: View {
    static let windowID = "battery-info"

    @EnvironmentObject private var monitor: BatteryMonitor

    private var snapshot: BatterySnapshot { monitor.snapshot }

    var body: some View {
        Group {
            // Without a battery every tab would be a wall of em dashes, which
            // reads as a broken window rather than as a Mac that has no battery.
            if snapshot.isPresent { tabs } else { noBattery }
        }
        // Tall enough for the longest tab, so the window keeps still while
        // tabbing; wide enough for three stat tiles to sit side by side.
        .frame(minWidth: 440, idealWidth: 500, minHeight: 420, idealHeight: 520)
        // On the window, not on each tab: switching tabs must not move the count.
        .onAppear { monitor.beginDetailUpdates() }
        .onDisappear { monitor.endDetailUpdates() }
    }

    private var tabs: some View {
        TabView {
            ChargeTab(snapshot: snapshot, log: monitor.chargeLog)
                .tabItem { Label("Charge", systemImage: "battery.75percent") }
                .keyboardShortcut("1")
            PowerTab(snapshot: snapshot, load: monitor.load)
                .tabItem { Label("Power", systemImage: "bolt") }
                .keyboardShortcut("2")
            HealthTab(snapshot: snapshot, log: monitor.capacityLog)
                .tabItem { Label("Health", systemImage: "heart.text.square") }
                .keyboardShortcut("3")
            if let lifetime = snapshot.lifetime {
                LifetimeTab(lifetime: lifetime)
                    .tabItem { Label("Lifetime", systemImage: "clock.arrow.circlepath") }
                    .keyboardShortcut("4")
            }
        }
    }

    private var noBattery: some View {
        ContentUnavailableView("No Battery", systemImage: "battery.slash",
                               description: Text("This Mac doesn't have a built-in battery."))
    }
}

// MARK: - Tabs

private struct ChargeTab: View {
    let snapshot: BatterySnapshot
    let log: SampleLog

    var body: some View {
        HeroTab {
            HeroHeader(subject: "Charge",
                       symbol: snapshot.isCharging ? "battery.100percent.bolt" : "battery.100percent",
                       variableValue: snapshot.isPresent ? Double(snapshot.percentage) / 100 : 0,
                       tint: snapshot.chargeTint,
                       value: snapshot.isPresent ? "\(snapshot.percentage)" : Fmt.unavailable,
                       unit: "%",
                       spokenUnit: "percent",
                       status: snapshot.statusText,
                       meta: meta,
                       info: """
                       How much charge is left, as the battery's own gauge \
                       reports it — the same figure macOS shows in the menu \
                       bar. The line below is what it adds up to in mAh, and \
                       how warm the battery is right now.
                       """)
        } tiles: {
            StatTile("Time to full", Fmt.minutes(snapshot.timeToFull), info: """
                     The gauge's own estimate of how long until the battery is \
                     full, at the rate power is flowing right now. It moves as \
                     that rate changes, and it is blank until the gauge has \
                     enough to go on.
                     """)
            StatTile("Time to empty", Fmt.minutes(snapshot.timeToEmpty), info: """
                     The gauge's own estimate of how long the charge will last \
                     at the rate the Mac is using it right now. Doing something \
                     heavier shortens it immediately.
                     """)
            StatTile("Low Power Mode", snapshot.lowPowerMode ? "On" : "Off", info: """
                     macOS's own setting, not OpenBattery's. It lowers display \
                     brightness and background activity to stretch the charge. \
                     Turn it on in System Settings, under Battery.
                     """)
        } detail: {
            DetailSection("Last 12 hours", caption: "charge level", info: """
                          The charge OpenBattery wrote down while it was \
                          running, one bar per hour. Hours are empty where \
                          nothing was recorded — the Mac was asleep, or the \
                          app was not running. The battery keeps no history of \
                          its own, so this starts from the day you install it.
                          """) {
                BucketChart(buckets: log.bucketed(),
                            tint: .green,
                            domain: 0...100,
                            label: { "\($0)%" },
                            axis: .hour,
                            empty: "No readings yet. The chart fills in while OpenBattery is running.")
            }
        }
    }

    private var meta: String {
        let capacity: String
        if let current = snapshot.currentCapacityMAh, let full = snapshot.fullChargeCapacityMAh {
            capacity = "\(Fmt.integer(current)) of \(Fmt.mAh(full))"
        } else {
            capacity = Fmt.mAh(snapshot.currentCapacityMAh)
        }
        return "\(capacity)  ·  \(Fmt.celsius(snapshot.temperature))"
    }
}

private struct PowerTab: View {
    let snapshot: BatterySnapshot
    let load: [BatteryMonitor.LoadSample]

    var body: some View {
        HeroTab {
            HeroHeader(subject: "Power draw",
                       symbol: snapshot.isPluggedIn ? "powerplug.fill" : "battery.100percent",
                       variableValue: snapshot.isPluggedIn ? nil : Double(snapshot.percentage) / 100,
                       tint: snapshot.isPluggedIn ? .blue : snapshot.chargeTint,
                       value: Fmt.decimal(headlineWatts),
                       unit: "W",
                       spokenUnit: "watts",
                       status: status,
                       meta: meta,
                       info: """
                       With an adapter connected, what the adapter is \
                       delivering. On battery, what the battery is giving up. \
                       The line below describes the adapter itself.
                       """)
        } tiles: {
            StatTile("Battery", Fmt.watts(snapshot.batteryWatts, signed: true), info: """
                     Power flowing into the battery (+) or out of it (−). \
                     Near zero on a full battery that is plugged in: the \
                     adapter is carrying the Mac and the battery is idle.
                     """)
            StatTile("Battery voltage", Fmt.volts(snapshot.volts), info: """
                     The voltage across the battery's cells. It climbs as the \
                     battery charges and falls as it drains, which is one of \
                     the things the gauge uses to work out the percentage.
                     """)
            StatTile("Battery current", Fmt.amps(snapshot.amps), info: """
                     The current flowing into or out of the battery. Multiply \
                     it by the voltage beside it and you get the watts on the \
                     left.
                     """)
        } detail: {
            DetailSection("System load", caption: "last 60 seconds", info: """
                          What the machine itself is drawing, sampled every \
                          few seconds while this window is open. It is the \
                          load, not the charging: a Mac drawing more than the \
                          adapter supplies makes up the difference from the \
                          battery.
                          """) {
                LoadChart(samples: load, isAvailable: snapshot.systemWatts != nil)
            }
        }
    }

    /// The number that answers "how much power is moving": what the adapter
    /// delivers when there is one, what the battery gives up when there is not.
    private var headlineWatts: Double? {
        snapshot.isPluggedIn ? snapshot.adapterWatts : snapshot.batteryWatts.map(abs)
    }

    private var status: String {
        guard snapshot.isPluggedIn else { return "Running on battery" }
        guard let watts = snapshot.batteryWatts else { return "On power adapter" }
        if watts > 0.05 { return "Charging from the adapter" }
        if watts < -0.05 { return "The adapter can't keep up · drawing from the battery" }
        return "Drawing from the adapter · battery idle"
    }

    private var meta: String {
        guard snapshot.isPluggedIn else {
            return "No adapter connected  ·  system \(Fmt.watts(snapshot.systemWatts))"
        }
        let parts = [
            snapshot.adapterRatedWatts.map { "\($0) W" },
            snapshot.adapterVolts.map { Fmt.volts($0) },
            snapshot.adapterAmps.map { Fmt.amps($0) },
        ].compactMap { $0 }
        let summary = parts.joined(separator: "  ·  ")
        guard let description = snapshot.adapterDescription, !description.isEmpty else {
            return summary.isEmpty ? "Power adapter" : summary
        }
        return summary.isEmpty ? description : "\(description)  ·  \(summary)"
    }

}

private struct HealthTab: View {
    let snapshot: BatterySnapshot
    let log: SampleLog

    var body: some View {
        HeroTab {
            // The tab's own symbol, not the Charge tab's battery: a part-filled
            // battery means "this much charge" everywhere else on the screen.
            HeroHeader(subject: "Battery health",
                       symbol: "heart.text.square",
                       tint: tint,
                       value: Fmt.decimal(snapshot.healthPercent),
                       unit: "%",
                       spokenUnit: "percent",
                       status: status,
                       meta: meta,
                       info: """
                       How much of its original capacity the battery still \
                       holds: what it charges to today, over what it was built \
                       to hold. Apple calls a battery normal above 80% and \
                       suggests service below it.
                       """)
        } tiles: {
            StatTile("Cycles", Fmt.integer(snapshot.cycleCount), info: """
                     A cycle is one full charge's worth of use, not one \
                     plug-in: two days at half a charge each count as one. \
                     There is no published number of cycles at which a Mac \
                     needs service, so this is a count, not a countdown.
                     """)
            StatTile("Age", Fmt.count(snapshot.ageInDays, "day"), info: """
                     Days since the cell was manufactured, which is not the \
                     same as how long you have had the Mac — a battery is \
                     usually some months old by the time the machine ships.
                     """)
            StatTile("Nominal", Fmt.mAh(snapshot.nominalCapacityMAh), info: """
                     The capacity the gauge advertises to the system. Apple \
                     does not document how it differs from the measured full \
                     charge above, which is the figure the health percentage \
                     uses; expect them to be close but not identical.
                     """)
        } detail: {
            DetailSection("Last 12 months", caption: "capacity retained", info: """
                          Full charge capacity as a share of the design \
                          capacity, written down once a day. Months are empty \
                          until they pass with OpenBattery installed — a year \
                          of this chart takes a year to fill.
                          """) {
                BucketChart(buckets: retained,
                            tint: isHealthy == false ? .orange : .green,
                            domain: 0...100,
                            label: { "\($0)%" },
                            axis: .month,
                            empty: "Capacity is written down once a day. The months fill in as they pass.")
            }
            InfoRows {
                InfoRow("Manufactured", Fmt.date(snapshot.manufactureDate), info: """
                        When the cell was made, decoded from the battery's own \
                        serial data. Apple does not publish the encoding, so \
                        treat it as close rather than exact.
                        """)
                // Spelled out: VoiceOver reads a serial number as a word.
                InfoRow("Serial number", snapshot.serialNumber ?? Fmt.unavailable, info: """
                        The battery's serial number, not the Mac's. A service \
                        centre uses it to tell whether the cell has been \
                        replaced.
                        """, spellsOut: true)
                InfoRow("Gauge", snapshot.deviceName ?? Fmt.unavailable, info: """
                        The chip inside the battery that measures it. Every \
                        number in this window comes from it, which is why they \
                        can differ slightly from what other tools report.
                        """)
            }
        }
    }

    /// Apple's own threshold for a battery it still considers normal, and nil
    /// when there is no capacity to judge — an unknown battery must not be
    /// painted with a verdict the app does not have.
    private var isHealthy: Bool? { snapshot.healthPercent.map { $0 >= 80 } }

    private var tint: Color {
        guard let isHealthy else { return .secondary }
        return isHealthy ? .green : .orange
    }

    /// Only capacity is judged. The gauge also reports a design cycle count,
    /// but nothing documents it as the point where a battery needs service,
    /// and it is not the same number across machines — counting cycles
    /// against it would be inventing a threshold.
    private var status: String {
        guard let isHealthy else { return "Capacity unknown" }
        return isHealthy ? "Normal · no service recommended"
                         : "Below 80% of design capacity · service recommended"
    }

    private var meta: String {
        let capacity: String
        if let full = snapshot.fullChargeCapacityMAh, let design = snapshot.designCapacityMAh {
            capacity = "\(Fmt.integer(full)) of \(Fmt.integer(design)) mAh design"
        } else {
            capacity = Fmt.mAh(snapshot.fullChargeCapacityMAh)
        }
        // The cycle count lives in its own tile a line below; saying it twice
        // in one block only makes both harder to find.
        return capacity
    }

    /// The log stores mAh; a year of raw mAh all looks the same, so the chart
    /// shows what it means — how much of the design capacity is still there.
    private var retained: [SampleLog.Bucket] {
        guard let design = snapshot.designCapacityMAh, design > 0 else { return [] }
        return log.bucketed().map {
            SampleLog.Bucket(date: $0.date, value: $0.value.map { $0 * 100 / design })
        }
    }
}

private struct LifetimeTab: View {
    let lifetime: BatterySnapshot.Lifetime

    var body: some View {
        HeroTab {
            HeroHeader(subject: "Average temperature",
                       symbol: "thermometer.medium",
                       tint: .orange,
                       value: Fmt.decimal(lifetime.averageTemperature),
                       unit: "°C avg",
                       spokenUnit: "degrees Celsius average",
                       status: status,
                       meta: meta,
                       info: """
                       The average temperature the battery has recorded across \
                       its whole life, not today. Heat is what ages a \
                       lithium-ion cell fastest, so a low lifetime average is \
                       worth more than a cool afternoon.
                       """)
        } tiles: {
            StatTile("Temperature range", temperatureRange, info: """
                     The coldest and the hottest the battery has ever recorded \
                     since it was made. A single hot afternoon stays in this \
                     figure forever.
                     """)
            StatTile("Voltage range", voltageRange, info: """
                     The lowest and highest voltage the battery has ever \
                     recorded. The low end is roughly how empty it has been \
                     allowed to get.
                     """)
            StatTile("Operating time", operatingTime, info: """
                     The gauge's own lifetime counter. Its unit is not \
                     documented by Apple — hours is the reading that matches \
                     reality on the machines this was checked against, so take \
                     it as an order of magnitude.
                     """)
        } detail: {
            DetailSection("Extremes", caption: "peak charge / discharge current", info: """
                          The largest currents the battery has ever recorded, \
                          measured against each other. Charging peaks are \
                          usually the higher of the two, since discharge is \
                          spread across whatever the Mac is doing.
                          """) {
                ExtremeBars(charge: lifetime.maximumChargeCurrentMA,
                            discharge: lifetime.maximumDischargeCurrentMA)
            }
        }
    }

    /// Lithium-ion is happiest well under 35 °C; this is the lifetime average,
    /// so a warm reading means warm for years, not warm this afternoon.
    private var status: String {
        guard let average = lifetime.averageTemperature else { return "No temperature record" }
        if average > 35 { return "Warmer than the ideal operating range" }
        if average < 15 { return "Cooler than the ideal operating range" }
        return "Within the ideal operating range"
    }

    private var meta: String {
        guard let raw = lifetime.operatingTimeRaw else {
            return Fmt.count(lifetime.temperatureSamples, "sample")
        }
        let days = BatteryDecoding.temperatureRecordDays(operatingTimeRawHours: raw)
        return "\(Fmt.days(days)) recorded  ·  \(Fmt.count(lifetime.temperatureSamples, "sample"))"
    }

    private var temperatureRange: String {
        guard lifetime.minimumTemperature != nil || lifetime.maximumTemperature != nil else {
            return "—"
        }
        return "\(Fmt.decimal(lifetime.minimumTemperature)) … \(Fmt.celsius(lifetime.maximumTemperature))"
    }

    private var voltageRange: String {
        guard lifetime.minimumVoltage != nil || lifetime.maximumVoltage != nil else { return "—" }
        return "\(Fmt.decimal(lifetime.minimumVoltage, places: 2)) … \(Fmt.volts(lifetime.maximumVoltage))"
    }

    /// The raw counter's unit is an assumption, not a documented fact — see
    /// `BatteryDecoding.operatingTime`.
    private var operatingTime: String {
        guard let raw = lifetime.operatingTimeRaw else { return "—" }
        return "\(Fmt.integer(BatteryDecoding.operatingTime(rawHours: raw).hours)) h"
    }
}

// MARK: - Shared layout

extension ShapeStyle where Self == Color {
    /// Quieter than a reading, louder than chrome: `.secondary` is about 4:1
    /// on a light window, under the 4.5:1 that text carrying or naming a
    /// number has to clear. Used for every label that qualifies a value.
    static var subdued: Color { Color.primary.opacity(0.7) }
}

/// The shape every tab takes: headline, three tiles, detail underneath.
private struct HeroTab<Tiles: View, Detail: View>: View {
    @ViewBuilder let header: HeroHeader
    @ViewBuilder let tiles: Tiles
    @ViewBuilder let detail: Detail

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                HStack(alignment: .top, spacing: 10) { tiles }
                detail
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
    }
}

/// The headline reading: a symbol that shows it, the number, and two lines
/// that say what it means and what it is made of.
private struct HeroHeader: View {
    /// What the headline reading is called. The status line is a sentence,
    /// so it cannot name the info button.
    let subject: String
    let symbol: String
    var variableValue: Double? = nil
    let tint: Color
    let value: String
    let unit: String
    /// How the unit should be said, where the written form is an abbreviation
    /// VoiceOver would mangle ("°C avg").
    var spokenUnit: String? = nil
    let status: String
    let meta: String
    let info: String

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: symbol, variableValue: variableValue)
                .font(.system(size: 54))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
                // A fixed box so the text starts in the same place on every
                // tab: a thermometer is far narrower than a battery.
                .frame(width: 76)
                // Everything it shows is written beside it.
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    // A display figure, not body copy: macOS has no Dynamic
                    // Type, and the point of the tab is to be readable from
                    // across the desk.
                    Text(value)
                        .font(.system(size: 42, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .accessibilityHidden(true)
                    // Subordinate to the figure, but it is half the reading:
                    // .secondary measures under 4:1 on a light window.
                    Text(unit)
                        .font(.title3.weight(.medium))
                        .foregroundStyle(.subdued)
                        .accessibilityHidden(true)
                    InfoButton(title: subject, text: info)
                }
                // Not tinted: system green on a light window is about 1.8:1,
                // nowhere near the 4.5:1 this text needs. The symbol carries
                // the colour, the words carry the meaning.
                Text(status)
                    .font(.callout.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityHidden(true)
                Text(meta)
                    .font(.caption)
                    .foregroundStyle(.subdued)
                    .monospacedDigit()
                    .textSelection(.enabled)
                    // The container speaks all of this; only the button below
                    // has to stay a stop of its own.
                    .accessibilityHidden(true)
            }
            Spacer(minLength: 0)
        }
        // Contain, not combine: the info button has to stay reachable.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Fmt.spoken("\(value) \(spokenUnit ?? unit)"))
        .accessibilityValue(Fmt.spoken("\(status). \(meta)"))
    }

}

/// What a reading means, for the readings whose name does not say it.
///
/// A button rather than a tooltip alone: hover help is invisible to anyone
/// navigating by keyboard or VoiceOver, and these explanations are the only
/// place several of these numbers are defined at all.
private struct InfoButton: View {
    let title: String
    let text: String

    @State private var isShowing = false

    var body: some View {
        Button { isShowing = true } label: {
            Image(systemName: "info.circle")
                .imageScale(.small)
                // A glyph, not text: 3:1 is the bar, which .secondary clears,
                // and it keeps the button quieter than the label beside it.
                .foregroundStyle(.secondary)
                // The glyph is 11 pt; macOS wants at least 20 pt of target.
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The tooltip says what the button does; the popover holds the
        // explanation, because hover reaches neither keyboard nor VoiceOver.
        .help("About \(title)")
        .accessibilityLabel("About \(title)")
        .popover(isPresented: $isShowing, arrowEdge: .bottom) {
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 240, alignment: .leading)
                .padding(12)
        }
    }
}

/// One boxed reading. Title small and quiet, value large and selectable.
private struct StatTile: View {
    let title: String
    let value: String
    let info: String

    init(_ title: String, _ value: String, info: String) {
        self.title = title
        self.value = value
        self.info = info
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Two lines rather than shrinking: at the minimum window width a
            // title like "Temperature range" needs less than 10 pt to fit on
            // one, and 10 pt is the macOS floor. Reserved so the three tiles
            // keep the same height whether or not their titles wrap.
            HStack(alignment: .top, spacing: 2) {
                SectionLabel(title)
                    .lineLimit(2, reservesSpace: true)
                    // The value below is announced with this as its label.
                    .accessibilityHidden(true)
                Spacer(minLength: 0)
                InfoButton(title: title, text: info)
                    // Sits above the title's own box so the two line up.
                    .offset(x: 6, y: -4)
            }
            Text(value)
                .font(.title3.weight(.medium))
                .monospacedDigit()
                .textSelection(.enabled)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .accessibilityLabel(title)
                .accessibilityValue(Fmt.spoken(value))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .tileBackground()
        // Contain, not ignore: the info button has to stay reachable.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

/// The boxed surface the tiles and the extremes sit on.
private struct TileBackground: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content.background {
            let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
            // The bare hierarchical tier, not an opacity of it: dimming
            // quaternary any further leaves a box that cannot be seen.
            shape.fill(.quaternary)
                // Increase Contrast asks for stronger separation, not the
                // same fill.
                .overlay { shape.strokeBorder(.separator, lineWidth: contrast == .increased ? 1 : 0) }
        }
    }
}

private extension View {
    func tileBackground() -> some View { modifier(TileBackground()) }
}

/// A titled block under the tiles: the chart, or whatever else the tab ends on.
private struct DetailSection<Content: View>: View {
    let title: String
    let caption: String
    let info: String
    @ViewBuilder let content: Content

    init(_ title: String, caption: String, info: String,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.caption = caption
        self.info = info
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                SectionLabel(title).accessibilityAddTraits(.isHeader)
                InfoButton(title: title, text: info)
                Spacer()
                // Never .tertiary: at this size it measures under 2:1 against
                // the window in both appearances.
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    // Spoken as part of the chart's own name, below.
                    .accessibilityHidden(true)
            }
            // Names the chart for VoiceOver, which would otherwise land on
            // an unlabelled group of marks.
            content
                .accessibilityElement(children: .contain)
                .accessibilityLabel("\(title), \(caption)")
        }
    }
}

private struct SectionLabel: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        // Names a value, so it reads at the same tier as one; and no scale
        // factor, because 10 pt is already the smallest legible size on macOS.
        Text(text)
            .font(.caption2.weight(.semibold))
            .textCase(.uppercase)
            .tracking(0.4)
            .foregroundStyle(.subdued)
            // Take the width offered and grow downwards. Without this the
            // label is laid out at its ideal single-line width and truncates
            // in a narrow tile instead of wrapping.
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Charts

/// One bar per bucket, with the empty ones simply missing.
private struct BucketChart: View {
    let buckets: [SampleLog.Bucket]
    let tint: Color
    let domain: ClosedRange<Int>
    let label: (Int) -> String
    let axis: Calendar.Component
    let empty: String

    @State private var pointer: Date?

    var body: some View {
        if buckets.contains(where: { $0.value != nil }) {
            chart
        } else {
            EmptyChart(text: empty)
        }
    }

    /// The bucket the pointer is over, if that bucket has a reading. Gaps
    /// are normal — nothing is recorded while the Mac sleeps — and pointing
    /// at one shows nothing, rather than jumping the rule back to an earlier
    /// hour that does have a bar.
    private var selected: SampleLog.Bucket? {
        guard let pointer else { return nil }
        return buckets.last { $0.date <= pointer }.flatMap { $0.value == nil ? nil : $0 }
    }

    private var chart: some View {
        Chart {
            ForEach(buckets) { bucket in
                if let value = bucket.value {
                    BarMark(x: .value("When", bucket.date, unit: axis),
                            y: .value("Value", value))
                        // Accepted risk, light mode: system green is 2.22:1
                        // on the window and 1.98:1 on the plot fill, under the
                        // 3:1 WCAG asks of a graphical object (dark is ~6.9:1).
                        // Kept because the reading never depends on resolving a
                        // bar against its background — the axis is labelled,
                        // every mark is spoken, and the chart is named.
                        .foregroundStyle(tint.gradient)
                        .cornerRadius(4)
                        .accessibilityLabel(Text(bucket.date, format: axisLabelFormat))
                        .accessibilityValue(label(value))
                }
            }
            if let selected, let value = selected.value {
                RuleMark(x: .value("When", selected.date, unit: axis))
                    // Explicit, not .secondary: inside a Chart the
                    // hierarchical tiers resolve against the series colour.
                    .foregroundStyle(Color.primary.opacity(0.55))
                    .annotation(position: .top, spacing: 4,
                                // The plot, not the chart: fitting to the
                                // chart lets the readout cover the axis labels.
                                overflowResolution: .init(x: .fit(to: .plot), y: .fit(to: .plot))) {
                        ChartReadout("\(axisLabelFormat.format(selected.date))  ·  \(label(value))")
                    }
                    // The bars it points at are already spoken, one by one.
                    .accessibilityHidden(true)
            }
        }
        // Twelve bars against three gridlines: the pointer is how anyone
        // reads an exact value off this, and macOS expects it to work.
        .chartXSelection(value: $pointer)
        .chartPlotStyle { $0.background(Color.primary.opacity(0.06)) }
        .chartYScale(domain: domain)
        .chartYAxis {
            AxisMarks(values: [domain.lowerBound, (domain.lowerBound + domain.upperBound) / 2,
                               domain.upperBound]) { value in
                AxisGridLine()
                AxisValueLabel { if let number = value.as(Int.self) { Text(label(number)) } }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: axis, count: axis == .hour ? 3 : 2)) {
                AxisGridLine()
                AxisValueLabel(format: axisLabelFormat)
            }
        }
        .frame(height: 120)
    }

    /// Pinned rather than inherited: an axis would otherwise format itself
    /// in the system language while the rest of this English interface does
    /// not. English words, the user's own 12- or 24-hour clock.
    private var axisLabelFormat: Date.FormatStyle {
        (axis == .hour ? Date.FormatStyle.dateTime.hour()
                       : Date.FormatStyle.dateTime.month(.abbreviated))
            .locale(Fmt.dateLocale)
    }
}

/// System load over the last minute. A line, not bars: this one is a trend,
/// sampled every few seconds, not a reading per period.
private struct LoadChart: View {
    let samples: [BatteryMonitor.LoadSample]
    /// Not every Mac publishes a system load figure, and promising a sample
    /// that is never coming is worse than saying so.
    let isAvailable: Bool

    @State private var pointer: Date?

    var body: some View {
        if samples.count > 1 {
            chart
        } else if isAvailable {
            EmptyChart(text: "Sampling system load…")
        } else {
            EmptyChart(text: "This Mac doesn't report what the system is drawing.")
        }
    }

    /// The sample nearest the pointer, since this series is continuous
    /// rather than one reading per period.
    private var selected: BatteryMonitor.LoadSample? {
        guard let pointer else { return nil }
        return samples.min { abs($0.date.timeIntervalSince(pointer))
                           < abs($1.date.timeIntervalSince(pointer)) }
    }

    private var chart: some View {
        Chart {
            ForEach(samples) { sample in
                AreaMark(x: .value("Time", sample.date), y: .value("Watts", sample.watts))
                    .foregroundStyle(.blue.opacity(0.2))
                    .interpolationMethod(.monotone)
                    // Fill only: the line below plots the same samples, and
                    // VoiceOver would otherwise read every watt reading twice.
                    .accessibilityHidden(true)
                LineMark(x: .value("Time", sample.date), y: .value("Watts", sample.watts))
                    .foregroundStyle(.blue)
                    .interpolationMethod(.monotone)
                    .accessibilityLabel(Text(sample.date,
                                             format: .dateTime.hour().minute().second()))
                    .accessibilityValue(Fmt.watts(sample.watts))
            }
            if let selected {
                RuleMark(x: .value("Time", selected.date))
                    .foregroundStyle(Color.primary.opacity(0.55))
                    .annotation(position: .top, spacing: 4,
                                overflowResolution: .init(x: .fit(to: .plot), y: .fit(to: .plot))) {
                        ChartReadout(Fmt.watts(selected.watts))
                    }
                    // The line it points at is already spoken, sample by sample.
                    .accessibilityHidden(true)
            }
        }
        .chartXSelection(value: $pointer)
        .chartPlotStyle { $0.background(Color.primary.opacity(0.06)) }
        .chartYScale(domain: 0...ceiling)
        .chartYAxis {
            AxisMarks(values: .automatic(desiredCount: 3)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let watts = value.as(Double.self) { Text(Fmt.watts(watts)) }
                }
            }
        }
        // Sixty seconds of wall clock times would be noise; the section title
        // says what the axis is.
        .chartXAxis(.hidden)
        .frame(height: 120)
    }

    /// Headroom above the peak so the line never touches the top edge.
    private var ceiling: Double {
        max(5, ((samples.map(\.watts).max() ?? 0) * 1.2).rounded(.up))
    }
}

/// What the pointer is over, floated above the mark it belongs to.
private struct ChartReadout: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption)
            .monospacedDigit()
            // Explicit: annotation content inherits the chart's foreground
            // style, which is whatever the mark it hangs off was drawn in.
            .foregroundStyle(.primary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.background))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.separator))
    }
}

private struct EmptyChart: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.subdued)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, minHeight: 120)
            .padding(.horizontal, 20)
    }
}

/// The two current records, drawn against whichever of them is larger.
private struct ExtremeBars: View {
    let charge: Int?
    let discharge: Int?

    private var peak: Double { Double(max(charge ?? 0, discharge ?? 0, 1)) }

    var body: some View {
        VStack(spacing: 8) {
            row("Max charge", charge, .green)
            row("Max discharge", discharge, .orange)
        }
        .padding(12)
        .tileBackground()
    }

    private func row(_ title: String, _ milliamps: Int?, _ tint: Color) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.callout)
                .frame(width: 100, alignment: .leading)
            // Two capsules rather than a Gauge: this is one record measured
            // against the other, not progress towards a goal.
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(tint)
                        .frame(width: geometry.size.width * Double(milliamps ?? 0) / peak)
                }
            }
            .frame(height: 8)
            Text(Fmt.mA(milliamps))
                .font(.callout)
                .monospacedDigit()
                .frame(width: 76, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(Fmt.spoken(Fmt.mA(milliamps)))
    }
}

// MARK: - Building blocks

/// A short list of readings that are worth keeping but not worth a tile.
private struct InfoRows<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct InfoRow: View {
    let label: String
    let value: String
    let info: String
    let spellsOut: Bool

    init(_ label: String, _ value: String, info: String, spellsOut: Bool = false) {
        self.label = label
        self.value = value
        self.info = info
        self.spellsOut = spellsOut
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.subdued)
                // The value below is announced with this as its label.
                .accessibilityHidden(true)
            InfoButton(title: label, text: info)
            Spacer(minLength: 12)
            Text(value)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .textSelection(.enabled)
                .accessibilityLabel(label)
                .accessibilityValue(spokenValue)
        }
        .font(.callout)
        // Contain, not ignore: the info button has to stay reachable.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }

    /// The spell-out has to ride on the value itself: an attribute set on a
    /// child Text is dropped when the value is handed to accessibilityValue.
    private var spokenValue: Text {
        var spoken = AttributedString(Fmt.spoken(value))
        // Nothing to spell out when there is no reading: "Not available" is
        // a sentence, not a serial number.
        spoken.accessibilitySpeechSpellsOutCharacters = spellsOut && value != Fmt.unavailable
        return Text(spoken)
    }
}
