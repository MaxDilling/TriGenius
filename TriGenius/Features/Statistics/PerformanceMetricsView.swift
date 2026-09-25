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
                          unit: "ml/kg/min", storageUnit: "ml_kg_min", format: intFormat, parse: doubleParse, higherIsBetter: true),
        PerformanceMetric(key: "vo2max_cycling", title: "VO₂max (Bike)", group: .performance, accent: SportFamily.bike.color,
                          unit: "ml/kg/min", storageUnit: "ml_kg_min", format: intFormat, parse: doubleParse, higherIsBetter: true),
        PerformanceMetric(key: "cycling_ftp", title: "FTP (Bike)", group: .performance, accent: SportFamily.bike.color,
                          unit: "W", storageUnit: "watts", format: intFormat, parse: doubleParse, higherIsBetter: true,
                          estimateNote: "Estimated from cycling VO₂max and weight."),
        PerformanceMetric(key: "running_ftp", title: "FTP (Run)", group: .performance, accent: SportFamily.run.color,
                          unit: "W", storageUnit: "watts", format: intFormat, parse: doubleParse, higherIsBetter: true),
        PerformanceMetric(key: "lactate_threshold_hr", title: "LTHR (Run)", group: .performance, accent: SportFamily.run.color,
                          unit: "bpm", storageUnit: "bpm", format: intFormat, parse: doubleParse, higherIsBetter: true,
                          estimateNote: "Estimated from max HR and recent sustained runs."),
        PerformanceMetric(key: "lactate_threshold_hr_cycling", title: "LTHR (Bike)", group: .performance, accent: SportFamily.bike.color,
                          unit: "bpm", storageUnit: "bpm", format: intFormat, parse: doubleParse, higherIsBetter: true,
                          estimateNote: "Estimated from the heart rate held in rides near your best 20-minute power."),
        PerformanceMetric(key: "lactate_threshold_speed", title: "LT Pace", group: .performance, accent: SportFamily.run.color,
                          unit: "/km", storageUnit: "m_per_s", format: paceFromSpeed(1000), parse: speedFromPace(1000), higherIsBetter: true, paceDistanceM: 1000,
                          estimateNote: "Reconstructed from heart rate and pace on recent runs."),
        PerformanceMetric(key: "swim_css_speed", title: "CSS", group: .performance, accent: SportFamily.swim.color,
                          unit: "/100m", storageUnit: "m_per_s", format: paceFromSpeed(100), parse: speedFromPace(100), higherIsBetter: true, paceDistanceM: 100),
        PerformanceMetric(key: "max_hr", title: "Max HR", group: .performance, accent: Theme.Palette.body,
                          unit: "bpm", storageUnit: "bpm", format: intFormat, parse: doubleParse, higherIsBetter: true),
        PerformanceMetric(key: "weight_kg", title: "Weight", group: .performance, accent: Theme.Palette.body,
                          unit: "kg", storageUnit: "kg", format: oneDecimalFormat, parse: doubleParse, higherIsBetter: false),
        // Recovery (daily wellness signals)
        PerformanceMetric(key: "resting_hr", title: "Resting HR", group: .recovery, accent: Theme.Palette.recovery,
                          unit: "bpm", storageUnit: "bpm", format: intFormat, parse: doubleParse, higherIsBetter: false),
        PerformanceMetric(key: "hrv_overnight", title: "HRV (Overnight)", group: .recovery, accent: Theme.Palette.recovery,
                          unit: "ms", storageUnit: "ms", format: intFormat, parse: doubleParse, higherIsBetter: true),
        PerformanceMetric(key: "sleep_score", title: "Sleep Score", group: .recovery, accent: Theme.Palette.recovery,
                          unit: "", storageUnit: "", format: intFormat, parse: doubleParse, higherIsBetter: true),
        PerformanceMetric(key: "sleep_duration_h", title: "Sleep Duration", group: .recovery, accent: Theme.Palette.recovery,
                          unit: "h", storageUnit: "h", format: oneDecimalFormat, parse: doubleParse, higherIsBetter: true),
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
            SummaryTile(title: metric.title, color: metric.accent, date: points.last?.date,
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


    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                header
                if visiblePoints.last?.isEstimated == true, let note = metric.estimateNote {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
                chart.contentCard()
                stats
                manualSection
            }
            .padding(Theme.Spacing.l)
        }
        .background(Color.appBackground)
        .navigationTitle(metric.title)
        #if !os(macOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .rangeToolbar($range)
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
                HStack {
                    Text("Manual Entries").font(.headline)
                    Spacer()
                    Button { showAdd = true } label: { Image(systemName: "plus.circle.fill").font(.title3) }
                        .buttonStyle(.plain).foregroundStyle(.tint)
                }
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

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Circle().fill(metric.accent).frame(width: 9, height: 9)
            Text(visiblePoints.last.map { metric.display($0) } ?? "—")
                .font(.largeTitle.bold())
            Text(metric.unit).font(.subheadline).foregroundStyle(.secondary)
            Spacer()
            if let deltaText = trend.deltaText(metric) {
                HStack(spacing: 2) {
                    Image(systemName: trend.rawDelta > 0 ? "arrow.up" : "arrow.down")
                    Text(deltaText)
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(trend.isImproved ? Theme.Palette.success : Theme.Palette.warning)
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
                scrubMarks
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

    @ChartContentBuilder private var scrubMarks: some ChartContent {
        if let date = scrubDate,
           let p = visiblePoints.min(by: { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }) {
            RuleMark(x: .value("Scrub", p.date))
                .foregroundStyle(.secondary.opacity(0.6))
                .lineStyle(StrokeStyle(lineWidth: 1))
                .annotation(position: .top, spacing: 0,
                            overflowResolution: .init(x: .fit(to: .plot), y: .fit(to: .plot))) {
                    ChartTooltip(
                        title: p.date.formatted(.dateTime.day().month(.abbreviated).year()),
                        rows: [.init(color: metric.accent, label: metric.title,
                                     value: "\(metric.display(p)) \(metric.unit)")]
                    )
                }
        }
    }

    @ViewBuilder
    private var stats: some View {
        let values = visiblePoints.map(\.value)
        if let lo = values.min(), let hi = values.max() {
            let mean = values.reduce(0, +) / Double(values.count)
            HStack(spacing: Theme.Spacing.m) {
                stat("Low / High", "\(metric.format(lo)) – \(metric.format(hi))")
                stat("Mean", metric.format(mean))
                stat("Points", "\(visiblePoints.count)")
            }
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.subheadline.weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }
}
