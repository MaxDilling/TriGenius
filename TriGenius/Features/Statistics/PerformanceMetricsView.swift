import SwiftUI
import Charts

// MARK: - Performance Metrics (physiological markers)
//
// The athlete's physiological performance markers on the Statistics screen. Each
// marker is read as a time series from `TrainingDataStore.metricHistory(_:)` so
// its progression — not just the latest scalar — is charted: a current value, the
// trend vs the first stored point, and a sparkline.

/// One physiological marker the Statistics screen can display, with
/// everything needed to read, format and color it. Internal (not private): the
/// chat's metric-trend card validates its token key against this catalog and
/// reuses `MetricCard`.
struct PerformanceMetric: Identifiable {
    /// Which section the card belongs to.
    enum Group { case performance, recovery }

    /// snake_case metric key stored in the DB (see `TrainingDataStore.ingestMetrics`).
    let key: String
    let title: String
    let group: Group
    let accent: Color
    /// Label shown under the value (e.g. "W", "ml/kg/min", "/km").
    let unit: String
    /// Raw unit token stored on the `PerformanceMetricRecord` (e.g. "watts", "bpm",
    /// "m_per_s"), matching the sync path — used when writing a manual value.
    let storageUnit: String
    /// Renders a raw stored value as a display string.
    let format: (Double) -> String
    /// Parses a display string back into the raw stored value (inverse of `format`),
    /// or nil when the input is malformed — drives manual-entry validation.
    let parse: (String) -> Double?
    /// True when a rising value is an improvement (VO2max, FTP, HRV); false where
    /// a lower value is better (pace markers — stored as speed — and resting HR).
    let higherIsBetter: Bool
    /// Distance (m) the pace display runs over for speed-stored markers (100 for
    /// CSS, 1000 for LT pace); nil for plain numeric markers. Lets the coach's
    /// metric tools express deltas of a speed-stored series in pace seconds.
    var paceDistanceM: Double? = nil
    /// What a derived value for this marker was derived *from*, shown wherever a point
    /// is flagged estimated — the "~" says a number isn't measured, not where it came
    /// from. Nil for markers that only ever hold readings.
    var estimateNote: String? = nil
    /// What the marker is and how to read it, under its detail chart.
    let about: String

    var id: String { key }

    /// Recovery signals are noisy day to day, so their trend — the delta and the line
    /// drawn over the readings — runs on the trailing 7-day mean. Taken over the whole
    /// history before cutting to `range`, so the window's first days average a full
    /// week too. Nil where the readings already are the trend.
    func trendLine(_ points: [MetricPoint], in range: TimeRange) -> [MetricPoint]? {
        group == .recovery ? MetricPoint.rollingMeans(points).filter { range.contains($0.date) } : nil
    }

    /// The markers shown, in priority order. CSS / LT thresholds are stored as
    /// raw speed (m/s) and rendered back into "m:ss" pace for display.
    static let all: [PerformanceMetric] = [
        // Performance (physiological capacity)
        PerformanceMetric(key: "vo2max_running", title: "VO₂max (Run)", group: .performance, accent: SportFamily.run.color,
                          unit: "ml/kg/min", storageUnit: "ml_kg_min", format: intFormat, parse: doubleParse, higherIsBetter: true,
                          about: "VO₂max is the maximum amount of oxygen your body can take up and use each minute during all-out exercise, per kilogram of body weight. It is set by how much blood your heart pumps per minute and how much oxygen your muscles extract from it — the size of your endurance engine. Your watch estimates it from how fast you run at a given heart rate. It rises slowly with regular training, so look at the trend over weeks, not day to day."),
        PerformanceMetric(key: "vo2max_cycling", title: "VO₂max (Bike)", group: .performance, accent: SportFamily.bike.color,
                          unit: "ml/kg/min", storageUnit: "ml_kg_min", format: intFormat, parse: doubleParse, higherIsBetter: true,
                          about: "VO₂max is the maximum amount of oxygen your body can take up and use each minute during all-out exercise, per kilogram of body weight. It is set by how much blood your heart pumps per minute and how much oxygen your muscles extract from it — the size of your endurance engine. Your watch estimates it from the power you produce at a given heart rate, so it only appears if you ride with a power meter. It rises slowly with regular training, so look at the trend over weeks."),
        PerformanceMetric(key: "cycling_ftp", title: "FTP (Bike)", group: .performance, accent: SportFamily.bike.color,
                          unit: "W", storageUnit: "watts", format: intFormat, parse: doubleParse, higherIsBetter: true,
                          estimateNote: "Estimated from cycling VO₂max and weight.",
                          about: "FTP (Functional Threshold Power) is the highest power, in watts, you could hold for about an hour of hard riding. It sits close to your lactate threshold: below it, your body clears lactate as fast as your muscles produce it and you can keep going for a long time; above it, lactate accumulates and you tire within minutes. The app uses FTP to set your cycling training zones and to work out how hard each ride with power was. If it is out of date, those zones and numbers are off too."),
        PerformanceMetric(key: "running_ftp", title: "FTP (Run)", group: .performance, accent: SportFamily.run.color,
                          unit: "W", storageUnit: "watts", format: intFormat, parse: doubleParse, higherIsBetter: true,
                          about: "Running FTP is the highest power, in watts, you could hold for about an hour of hard running. Like cycling FTP, it marks the boundary between an effort you can sustain and one where lactate accumulates and you tire within minutes. It only exists if your watch or a foot pod measures running power. Devices measure running power differently, so compare it only with your own earlier values, never with someone else's."),
        PerformanceMetric(key: "lactate_threshold_hr", title: "LTHR (Run)", group: .performance, accent: SportFamily.run.color,
                          unit: "bpm", storageUnit: "bpm", format: intFormat, parse: doubleParse, higherIsBetter: true,
                          estimateNote: "Estimated from max HR and recent sustained runs.",
                          about: "LTHR (lactate threshold heart rate) is your heart rate at the point where lactate starts to accumulate in your muscles faster than your body can clear it. Below it you can keep going for a long time; above it you tire within minutes — in trained athletes it is roughly the effort you could hold for an hour. The app uses it to set your running heart-rate zones and to work out how hard a run was when no pace data is available."),
        PerformanceMetric(key: "lactate_threshold_hr_cycling", title: "LTHR (Bike)", group: .performance, accent: SportFamily.bike.color,
                          unit: "bpm", storageUnit: "bpm", format: intFormat, parse: doubleParse, higherIsBetter: true,
                          estimateNote: "Estimated from the heart rate held in rides near your best 20-minute power.",
                          about: "Your LTHR on the bike: the heart rate at which lactate starts to accumulate in your muscles faster than your body can clear it. It is usually a few beats lower than when running, because cycling works less muscle mass, so your heart does not need to pump as much blood — which is why the bike has its own value. The app uses it to set your cycling heart-rate zones and to work out how hard a ride was without a power meter."),
        PerformanceMetric(key: "lactate_threshold_speed", title: "LT Pace", group: .performance, accent: SportFamily.run.color,
                          unit: "/km", storageUnit: "m_per_s", format: paceFromSpeed(1000), parse: speedFromPace(1000), higherIsBetter: true, paceDistanceM: 1000,
                          estimateNote: "Reconstructed from heart rate and pace on recent runs.",
                          about: "LT pace (lactate threshold pace) is your running pace at the lactate threshold — the point where lactate accumulates in your muscles faster than your body can clear it. It is roughly the pace you could hold for an hour of hard running. The app uses it to set your running pace zones and to work out how hard each run was, with hills taken into account: uphill counts as harder, downhill as easier. A faster LT pace means you run faster at the same effort."),
        PerformanceMetric(key: "swim_css_speed", title: "CSS", group: .performance, accent: SportFamily.swim.color,
                          unit: "/100m", storageUnit: "m_per_s", format: paceFromSpeed(100), parse: speedFromPace(100), higherIsBetter: true, paceDistanceM: 100,
                          about: "CSS (Critical Swim Speed) is the fastest pace per 100 m you can keep up without steadily tiring — the swimming counterpart of your lactate threshold. It is usually found by swimming 400 m and 200 m as fast as you can: the 200 m difference in distance divided by the difference in time. The app uses it to work out how hard each swim was. A faster CSS means you swim faster at the same effort."),
        PerformanceMetric(key: "max_hr", title: "Max HR", group: .performance, accent: Theme.Palette.body,
                          unit: "bpm", storageUnit: "bpm", format: intFormat, parse: doubleParse, higherIsBetter: true,
                          about: "Your maximum heart rate is the highest your heart can beat at an all-out effort, and the upper end of your heart-rate range. It depends mostly on your genes and declines slowly with age — training barely changes it, so a higher max HR does not mean you are fitter. A new value usually just means your watch caught a harder effort than before."),
        PerformanceMetric(key: "weight_kg", title: "Weight", group: .performance, accent: Theme.Palette.body,
                          unit: "kg", storageUnit: "kg", format: oneDecimalFormat, parse: doubleParse, higherIsBetter: false,
                          about: "Your weight directly affects your VO₂max: at the same fitness, a lighter body gets a higher VO₂max and a heavier one a lower value. On the bike, less weight means faster climbs at the same power, because what counts uphill is watts per kilogram. Weight swings by 1–2 kg from day to day through water, food and stored carbohydrate (glycogen), so look at the trend over weeks."),
        // Recovery (daily wellness signals)
        PerformanceMetric(key: "resting_hr", title: "Resting HR", group: .recovery, accent: Theme.Palette.recovery,
                          unit: "bpm", storageUnit: "bpm", format: intFormat, parse: doubleParse, higherIsBetter: false,
                          about: "Your resting heart rate is how fast your heart beats when you are completely relaxed. Endurance training makes your heart stronger, so it pumps more blood per beat and needs fewer beats at rest — resting HR usually drops slowly as your fitness improves. If it is several beats higher than usual for a few days, your body may be tired, getting sick or stressed — a good time to take it easy. Single days jump around, so the bold line shows your 7-day average."),
        PerformanceMetric(key: "hrv_overnight", title: "HRV (Overnight)", group: .recovery, accent: Theme.Palette.recovery,
                          unit: "ms", storageUnit: "ms", format: intFormat, parse: doubleParse, higherIsBetter: true,
                          about: "HRV (heart rate variability) is how much the time between consecutive heartbeats varies, measured while you sleep. It reflects your autonomic nervous system: when its \"rest and recover\" side (parasympathetic) is in charge, the gaps vary more and HRV is high; hard training, illness, stress or alcohol shift it toward \"fight or flight\" (sympathetic) and HRV drops. A value in your usual range means you are ready for hard training; a clear drop means your body needs rest. HRV differs a lot between people, so only compare it with your own values; the bold line shows your 7-day average."),
        PerformanceMetric(key: "sleep_score", title: "Sleep Score", group: .recovery, accent: Theme.Palette.recovery,
                          unit: "", storageUnit: "", format: intFormat, parse: doubleParse, higherIsBetter: true,
                          about: "A score from 0 to 100 your watch gives each night, based on how long you slept, how much time you spent in deep and REM sleep, and how restless you were. Every manufacturer calculates it differently, so look at the trend rather than single nights. Several poor nights in a row mean your body recovers less from training."),
        PerformanceMetric(key: "sleep_duration_h", title: "Sleep Duration", group: .recovery, accent: Theme.Palette.recovery,
                          unit: "h", storageUnit: "h", format: oneDecimalFormat, parse: doubleParse, higherIsBetter: true,
                          about: "How long you slept. Most adults need 7–9 hours, and more when training a lot. Your body adapts to training mainly while you sleep: in deep sleep it releases most of its growth hormone, which drives muscle repair, and it refills its energy stores. Several short nights make training harder and less effective."),
    ]

    /// The markers the athlete can hand-enter (physiological capacity + weight);
    /// daily wellness signals are provider-driven and excluded.
    static let editable: [PerformanceMetric] = all.filter { $0.group == .performance }

    /// One point as the athlete reads it: an estimate is prefixed "~" so a derived
    /// number is never mistaken for a measured one.
    func display(_ point: MetricPoint) -> String {
        (point.isEstimated ? "~" : "") + format(point.value)
    }

    /// Catalog lookup by stored key — validates a chat card token's `key`.
    static func metric(for key: String) -> PerformanceMetric? {
        all.first { $0.key == key }
    }

    private static let intFormat: (Double) -> String = { String(Int($0.rounded())) }
    private static let oneDecimalFormat: (Double) -> String = { String(format: "%.1f", $0) }
    private static let doubleParse: (String) -> Double? = { Double($0.replacingOccurrences(of: ",", with: ".")) }
    /// Build a formatter turning a stored speed (m/s) into "m:ss" pace over `distanceM`.
    private static func paceFromSpeed(_ distanceM: Double) -> (Double) -> String {
        { speed in
            guard speed > 0 else { return "—" }
            let secs = distanceM / speed
            return String(format: "%d:%02d", Int(secs) / 60, Int(secs) % 60)
        }
    }
    /// Inverse of `paceFromSpeed`: parse "m:ss" pace over `distanceM` back into m/s.
    private static func speedFromPace(_ distanceM: Double) -> (String) -> Double? {
        { text in
            let parts = text.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let m = Int(parts[0]), let s = Int(parts[1]), s < 60 else { return nil }
            let secs = Double(m * 60 + s)
            return secs > 0 ? distanceM / secs : nil
        }
    }
}

// MARK: - Section

/// The grid of physiological-marker cards on the Statistics screen.
/// Reads each marker's history from the store on appear; renders nothing when
/// no marker has any data yet.
struct PerformanceMetricsSection: View {
    init(range: TimeRange) { self.range = range }

    let range: TimeRange

    private var wide = WideLayout()
    @State private var histories: [String: [MetricPoint]] = [:]
    @State private var loaded = false
    @State private var showAdd = false

    private func available(_ group: PerformanceMetric.Group) -> [PerformanceMetric] {
        PerformanceMetric.all.filter { $0.group == group && (histories[$0.key]?.isEmpty == false) }
    }

    var body: some View {
        // A concrete VStack (not a transparent `Group`) so the `.task` loader
        // fires reliably even while the section has nothing to show yet.
        VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                SectionHeading("Performance") {
                    Button { showAdd = true } label: {
                        Image(systemName: "plus.circle.fill").font(.title3)
                    }
                    .buttonStyle(.plain).foregroundStyle(.tint)
                    .accessibilityLabel("Add performance value")
                }
                let performance = available(.performance)
                if !performance.isEmpty {
                    grid(performance)
                } else if loaded {
                    Text("No performance metrics yet. VO₂max, FTP and your threshold values appear here once your data source reports them.")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .contentCard()
                }
            }

            let recovery = available(.recovery)
            if !recovery.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                    SectionHeading("Recovery")
                    grid(recovery)
                }
            }
        }
        .task { await load() }
        // A sync or manual entry appends to the metric time series; reload so the
        // cards reflect new values without leaving and re-entering the screen.
        .onReceive(NotificationCenter.default.publisher(for: .trainingDataDidChange)) { _ in
            Task { await load() }
        }
        .sheet(isPresented: $showAdd) { ManualMetricEntryView() }
    }

    private func grid(_ metrics: [PerformanceMetric]) -> some View {
        LazyVGrid(columns: SummaryTile.columns(wide: wide.isWide), spacing: Theme.Spacing.m) {
            ForEach(metrics) { metric in
                MetricCard(metric: metric, points: histories[metric.key] ?? [], range: range)
            }
        }
    }

    private func load() async {
        let store = TrainingDataStore.shared
        var result: [String: [MetricPoint]] = [:]
        for metric in PerformanceMetric.all {
            let points = await store.metricHistory(metric.key)
            if !points.isEmpty { result[metric.key] = points }
        }
        histories = result
        loaded = true
    }
}

// MARK: - Trend math

/// First-to-last change of a metric's trend within a range, plus whether that
/// change is an improvement. Shared by the card and the detail view so the
/// delta is computed identically everywhere.
private struct MetricTrend {
    let rawDelta: Double
    let isImproved: Bool

    init(metric: PerformanceMetric, points: [MetricPoint], range: TimeRange) {
        let points = metric.trendLine(points, in: range) ?? points.filter { range.contains($0.date) }
        let delta = (points.last?.value ?? 0) - (points.first?.value ?? 0)
        rawDelta = points.count >= 2 ? delta : 0
        isImproved = metric.higherIsBetter ? rawDelta > 0 : rawDelta < 0
    }

    func deltaText(_ metric: PerformanceMetric) -> String? {
        guard abs(rawDelta) >= 0.5 else { return nil }
        return metric.format(abs(rawDelta))
    }
}

// MARK: - Card

/// A marker's `SummaryTile`, opening its detail page at the same window. The chat's
/// metric-trend card reuses it.
struct MetricCard: View {
    let metric: PerformanceMetric
    let points: [MetricPoint]
    let range: TimeRange

    var body: some View {
        let recent = points.filter { range.contains($0.date) }
        let trend = MetricTrend(metric: metric, points: points, range: range)
        NavigationLink {
            MetricDetailView(metric: metric, points: points, range: range)
        } label: {
            SummaryTile(title: metric.title, color: metric.accent,
                        date: metric.group == .recovery ? nil : points.last?.date,
                        value: points.last.map(metric.display) ?? "—", unit: metric.unit,
                        delta: trend.deltaText(metric).map {
                            .init(value: $0, isRise: trend.rawDelta > 0,
                                  color: trend.isImproved ? Theme.Palette.success : Theme.Palette.warning)
                        },
                        series: recent, trendLine: metric.trendLine(points, in: range), display: metric.display)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Detail view

/// The chart + history for one marker, pushed from its tile and from Settings'
/// automatic-calculation screen.
struct MetricDetailView: View {
    let metric: PerformanceMetric
    let points: [MetricPoint]

    @State private var range: TimeRange
    @State private var scrubDate: Date?
    @State private var manualEntries: [MetricPoint] = []
    @State private var showAdd = false
    @State private var editEntry: MetricPoint?

    init(metric: PerformanceMetric, points: [MetricPoint], range: TimeRange = .threeMonths) {
        self.metric = metric
        self.points = points
        self._range = State(initialValue: range)
    }

    private var visiblePoints: [MetricPoint] {
        points.filter { range.contains($0.date) }
    }

    private var trend: MetricTrend { MetricTrend(metric: metric, points: points, range: range) }

    private var scrubbedPoint: MetricPoint? {
        scrubDate.flatMap { date in visiblePoints.first { $0.date == date } }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                readout
                if visiblePoints.last?.isEstimated == true, let note = metric.estimateNote {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
                chart
                stats
                SectionHeading("About \(metric.title)")
                Text(metric.about)
                    .font(.subheadline).foregroundStyle(.secondary)
                    .contentCard()
                manualSection
            }
            .padding(Theme.Spacing.l)
        }
        .background(Color.appBackground)
        .navigationTitle(metric.title)
        #if !os(macOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .rangeBar($range)
        .toolbar {
            if metric.group == .performance {
                ToolbarItem(placement: .primaryAction) {
                    Button("Add value", systemImage: "plus") { showAdd = true }
                }
            }
        }
        .task { manualEntries = TrainingDataStore.shared.manualMetricEntries(key: metric.key) }
        .onReceive(NotificationCenter.default.publisher(for: .trainingDataDidChange)) { _ in
            manualEntries = TrainingDataStore.shared.manualMetricEntries(key: metric.key)
        }
        .sheet(isPresented: $showAdd) { ManualMetricEntryView(defaultKey: metric.key) }
        .sheet(item: $editEntry) { p in
            ManualMetricEntryView(editing: .init(metric: metric, date: p.date, value: p.value))
        }
    }

    /// The athlete's hand-entered points for this marker, with add / edit / delete.
    /// Shown only for editable (physiological) markers, not provider-driven wellness.
    @ViewBuilder
    private var manualSection: some View {
        if metric.group == .performance {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeading("Manual Entries")
                if manualEntries.isEmpty {
                    Text("No manual values yet. Tap + to add one.")
                        .font(.subheadline).foregroundStyle(.secondary)
                } else {
                    ForEach(manualEntries.reversed()) { p in
                        HStack {
                            Text(p.date.formatted(.dateTime.day().month(.abbreviated).year()))
                                .font(.subheadline)
                            Spacer()
                            Text("\(metric.format(p.value)) \(metric.unit)")
                                .font(.subheadline.weight(.semibold))
                            Button(role: .destructive) {
                                TrainingDataStore.shared.deleteManualMetric(key: metric.key, date: p.date)
                            } label: {
                                Image(systemName: "trash").foregroundStyle(Theme.Palette.warning)
                            }
                            .buttonStyle(.plain)
                        }
                        .cardSurface()
                        .contentShape(Rectangle())
                        .onTapGesture { editEntry = p }
                    }
                }
            }
        }
    }

    /// Health-style readout: the latest value over the span charted, or the scrubbed
    /// reading on its own day.
    private var readout: some View {
        let scrubbed = scrubbedPoint
        return VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Circle().fill(metric.accent).frame(width: 9, height: 9)
                Text((scrubbed ?? visiblePoints.last).map(metric.display) ?? "—")
                    .font(.largeTitle.bold()).monospacedDigit()
                Text(metric.unit).font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                if let deltaText = trend.deltaText(metric) {
                    HStack(spacing: 2) {
                        Image(systemName: trend.rawDelta > 0 ? "arrow.up" : "arrow.down")
                        Text(deltaText)
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(trend.isImproved ? Theme.Palette.success : Theme.Palette.warning)
                    // The delta spans the range; it steps aside while one reading shows.
                    .opacity(scrubbed == nil ? 1 : 0)
                }
            }
            if let first = visiblePoints.first, let last = visiblePoints.last {
                Text(scrubbed.map { $0.date.formatted(.dateTime.day().month(.abbreviated).year()) }
                     ?? (first.date..<last.date).formatted(.interval.day().month(.abbreviated).year()))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var chart: some View {
        if visiblePoints.count >= 2 {
            Chart {
                // One `LineMark` per stretch, not per point: `lineStyle` applies to a
                // whole *series*, so a per-point dash makes the last point style the
                // entire line — which drew a 3-month window fully dashed and a 6-month
                // one fully solid off the same data.
                ForEach(MetricPoint.stretches(visiblePoints)) { stretch in
                    ForEach(stretch.points) { p in
                        LineMark(x: .value("Date", p.date), y: .value("Value", p.value),
                                 series: .value("Stretch", stretch.id))
                            .interpolationMethod(.linear)
                            .foregroundStyle(metric.accent.opacity(metric.group == .recovery ? 0.35 : 1))
                            // An estimate carried forward, or resting on a window too
                            // thin for the aggregate to be robust, is not a reading;
                            // drawn solid it is indistinguishable from one.
                            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round,
                                                   dash: stretch.isProvisional ? [1, 4] : []))
                    }
                }
                ForEach(metric.trendLine(points, in: range) ?? []) { p in
                    LineMark(x: .value("Date", p.date), y: .value("Value", p.value), series: .value("Stretch", -1))
                        .foregroundStyle(metric.accent)
                        .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round))
                }
                ForEach(visiblePoints) { p in
                    AreaMark(x: .value("Date", p.date), y: .value("Value", p.value))
                        .interpolationMethod(.linear)
                        .foregroundStyle(
                            .linearGradient(
                                colors: [metric.accent.opacity(0.25), metric.accent.opacity(0.02)],
                                startPoint: .top, endPoint: .bottom
                            )
                        )
                }
                if let p = scrubbedPoint {
                    RuleMark(x: .value("Scrub", p.date))
                        .foregroundStyle(.secondary.opacity(0.6))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                }
            }
            .chartScrubbing($scrubDate) { date in
                visiblePoints.min(by: { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) })?.date
            }
            .chartYScale(domain: tightDomain(visiblePoints))
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let v = value.as(Double.self) { Text(metric.format(v)) }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4))
            }
            // Clip the marks to the *plot* rect (not the whole frame) so the area
            // fill — which `.monotone` can push past the data — stops at the axes
            // and never paints over the x-axis labels below it.
            .chartPlotStyle { $0.clipped() }
            .frame(height: 240)
        } else {
            Text("Not enough data in this period to chart a trend.")
                .font(.subheadline).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 240)
        }
    }

    @ViewBuilder
    private var stats: some View {
        let values = visiblePoints.map(\.value)
        if let lo = values.min(), let hi = values.max() {
            let mean = values.reduce(0, +) / Double(values.count)
            HStack(spacing: Theme.Spacing.m) {
                stat("Low / High", "\(metric.format(lo)) – \(metric.format(hi))")
                Divider()
                stat("Mean", metric.format(mean))
                Divider()
                stat("Points", "\(visiblePoints.count)")
            }
            .fixedSize(horizontal: false, vertical: true)
            .cardSurface()
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.subheadline.weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
