import SwiftUI
import Charts

// MARK: - Performance Metrics (physiological markers)
//
// FEATURES.md "Erweitere Performance Insights um weitere Daten wie VO2Max, FTP,
// Laktatschwellenwert": the Performance Insights screen now surfaces the
// athlete's physiological performance markers next to the PMC chart. Each marker
// is read as a time series from `TrainingDataStore.metricHistory(_:)` so its
// progression — not just the latest scalar — is charted: a current value, the
// trend vs the first stored point, and a sparkline.

/// One physiological marker the Performance Insights screen can display, with
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
    /// Renders a raw stored value as a display string.
    let format: (Double) -> String
    /// True when a rising value is an improvement (VO2max, FTP, HRV); false where
    /// a lower value is better (pace markers — stored as speed — and resting HR).
    let higherIsBetter: Bool

    var id: String { key }

    /// The markers shown, in priority order. CSS / LT thresholds are stored as
    /// raw speed (m/s) and rendered back into "m:ss" pace for display.
    static let all: [PerformanceMetric] = [
        // Performance (physiological capacity)
        PerformanceMetric(key: "vo2max_running", title: "VO₂max (Run)", group: .performance, accent: .red,
                          unit: "ml/kg/min", format: intFormat, higherIsBetter: true),
        PerformanceMetric(key: "vo2max_cycling", title: "VO₂max (Bike)", group: .performance, accent: .orange,
                          unit: "ml/kg/min", format: intFormat, higherIsBetter: true),
        PerformanceMetric(key: "cycling_ftp", title: "FTP (Bike)", group: .performance, accent: .blue,
                          unit: "W", format: intFormat, higherIsBetter: true),
        PerformanceMetric(key: "running_ftp", title: "FTP (Run)", group: .performance, accent: .indigo,
                          unit: "W", format: intFormat, higherIsBetter: true),
        PerformanceMetric(key: "lactate_threshold_hr", title: "LT Heart Rate", group: .performance, accent: .pink,
                          unit: "bpm", format: intFormat, higherIsBetter: true),
        PerformanceMetric(key: "lactate_threshold_speed", title: "LT Pace", group: .performance, accent: .teal,
                          unit: "/km", format: paceFromSpeed(1000), higherIsBetter: true),
        PerformanceMetric(key: "swim_css_speed", title: "CSS (Swim)", group: .performance, accent: .cyan,
                          unit: "/100m", format: paceFromSpeed(100), higherIsBetter: true),
        PerformanceMetric(key: "max_hr", title: "Max Heart Rate", group: .performance, accent: .purple,
                          unit: "bpm", format: intFormat, higherIsBetter: true),
        // Recovery (daily wellness signals)
        PerformanceMetric(key: "resting_hr", title: "Resting HR", group: .recovery, accent: .mint,
                          unit: "bpm", format: intFormat, higherIsBetter: false),
        PerformanceMetric(key: "hrv_overnight", title: "HRV (Overnight)", group: .recovery, accent: .green,
                          unit: "ms", format: intFormat, higherIsBetter: true),
        PerformanceMetric(key: "sleep_score", title: "Sleep Score", group: .recovery, accent: .blue,
                          unit: "", format: intFormat, higherIsBetter: true),
    ]

    /// Catalog lookup by stored key — validates a chat card token's `key`.
    static func metric(for key: String) -> PerformanceMetric? {
        all.first { $0.key == key }
    }

    private static let intFormat: (Double) -> String = { String(Int($0.rounded())) }
    /// Build a formatter turning a stored speed (m/s) into "m:ss" pace over `distanceM`.
    private static func paceFromSpeed(_ distanceM: Double) -> (Double) -> String {
        { speed in
            guard speed > 0 else { return "—" }
            let secs = distanceM / speed
            return String(format: "%d:%02d", Int(secs) / 60, Int(secs) % 60)
        }
    }
}

// MARK: - Section

/// The grid of physiological-marker cards on the Performance Insights screen.
/// Reads each marker's history from the store on appear; renders nothing when
/// no marker has any data yet.
struct PerformanceMetricsSection: View {
    @State private var histories: [String: [MetricPoint]] = [:]
    @State private var loaded = false

    private func available(_ group: PerformanceMetric.Group) -> [PerformanceMetric] {
        PerformanceMetric.all.filter { $0.group == group && (histories[$0.key]?.isEmpty == false) }
    }

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 10)]

    var body: some View {
        // A concrete VStack (not a transparent `Group`) so the `.task` loader
        // fires reliably even while the section has nothing to show yet.
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Performance Metrics").font(.headline)
                let performance = available(.performance)
                if !performance.isEmpty {
                    grid(performance)
                } else if loaded {
                    Text("No performance metrics yet. VO₂max, FTP and your threshold values appear here once your data source reports them.")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Theme.Spacing.m)
                        .glassSurface(cornerRadius: Theme.Radius.l)
                }
            }

            let recovery = available(.recovery)
            if !recovery.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Recovery").font(.headline)
                    grid(recovery)
                }
            }
        }
        .task { load() }
        // A sync or manual entry appends to the metric time series; reload so the
        // cards reflect new values without leaving and re-entering the screen.
        .onReceive(NotificationCenter.default.publisher(for: .trainingDataDidChange)) { _ in
            load()
        }
    }

    private func grid(_ metrics: [PerformanceMetric]) -> some View {
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(metrics) { metric in
                MetricCard(metric: metric, points: histories[metric.key] ?? [])
            }
        }
    }

    private func load() {
        let store = TrainingDataStore.shared
        var result: [String: [MetricPoint]] = [:]
        for metric in PerformanceMetric.all {
            let points = store.metricHistory(metric.key)
            if !points.isEmpty { result[metric.key] = points }
        }
        histories = result
        loaded = true
    }
}

// MARK: - Trend math

/// First-to-last change of a metric over a set of points, plus whether that
/// change is an improvement. Shared by the card and the detail view so the
/// delta is computed identically everywhere.
private struct MetricTrend {
    let rawDelta: Double
    let isImproved: Bool

    init(metric: PerformanceMetric, points: [MetricPoint]) {
        let delta = (points.last?.value ?? 0) - (points.first?.value ?? 0)
        rawDelta = points.count >= 2 ? delta : 0
        isImproved = metric.higherIsBetter ? rawDelta > 0 : rawDelta < 0
    }

    func deltaText(_ metric: PerformanceMetric) -> String? {
        guard abs(rawDelta) >= 0.5 else { return nil }
        return metric.format(abs(rawDelta))
    }
}

/// A Y-axis domain tightened to the data's own min/max (plus a margin on each
/// side), so even small progressions fill the chart's height instead of
/// flattening against `.automatic`'s round-number padding. `bottomPad` can be
/// raised independently of `topPad` so the full-bleed card sparkline keeps the
/// line off the bottom edge (the area still fills the gap below it).
private func tightDomain(_ points: [MetricPoint], topPad: Double = 0.18, bottomPad: Double = 0.18) -> ClosedRange<Double> {
    let values = points.map(\.value)
    guard let lo = values.min(), let hi = values.max() else { return 0...1 }
    let range = hi - lo
    // A flat series has no range to scale by — fall back to a small synthetic span.
    let unit = range > 0 ? range : max(abs(hi) * 0.28, 1)
    return (lo - unit * bottomPad)...(hi + unit * topPad)
}

// MARK: - Card

struct MetricCard: View {
    let metric: PerformanceMetric
    let points: [MetricPoint]
    /// Sparkline window in months. The Statistics grid uses the 3-month default;
    /// the chat's metric-trend card passes its token's `months`.
    var windowMonths: Int

    @State private var showDetail = false
    @State private var scrubDate: Date?

    init(metric: PerformanceMetric, points: [MetricPoint], windowMonths: Int = 3) {
        self.metric = metric
        self.points = points
        self.windowMonths = windowMonths
    }

    /// The card sparkline summarises only the recent past — `windowMonths` —
    /// so day-to-day progression reads clearly without the whole history
    /// compressing it flat. (The detail view still offers longer windows.)
    /// The current value still comes from the full series' last point.
    private var recentPoints: [MetricPoint] {
        guard let start = Calendar.current.date(byAdding: .month, value: -windowMonths, to: Date()) else { return points }
        return points.filter { $0.date >= start }
    }

    private var trend: MetricTrend { MetricTrend(metric: metric, points: recentPoints) }

    /// The sparkline point under the pointer/finger — while scrubbing, the card's
    /// own value line becomes the readout (a floating tooltip has no room on the
    /// 36 pt footer).
    private var scrubbed: MetricPoint? {
        guard let date = scrubDate else { return nil }
        return recentPoints.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header + value carry the normal card padding…
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 5) {
                    Circle().fill(metric.accent).frame(width: 7, height: 7)
                    Text(metric.title).font(.caption).foregroundStyle(.secondary)
                }

                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text((scrubbed ?? points.last).map { metric.format($0.value) } ?? "—")
                        .font(.title2.bold())
                    Text(metric.unit).font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    if let scrubbed {
                        Text(scrubbed.date.formatted(.dateTime.day().month(.abbreviated)))
                            .font(.caption2).foregroundStyle(.secondary)
                    } else if let deltaText = trend.deltaText(metric) {
                        HStack(spacing: 1) {
                            Image(systemName: trend.rawDelta > 0 ? "arrow.up" : "arrow.down")
                            Text(deltaText)
                        }
                        .font(.caption2)
                        .foregroundStyle(trend.isImproved ? Theme.Palette.success : Theme.Palette.warning)
                    }
                }
            }
            .padding([.top, .horizontal], Theme.Spacing.m)

            // …while the sparkline runs edge-to-edge as a full-bleed footer,
            // clipped to the card's rounded bottom corners so it never pokes past.
            sparkline
                .frame(height: 36)
                .clipShape(.rect(
                    topLeadingRadius: 0, bottomLeadingRadius: Theme.Radius.l,
                    bottomTrailingRadius: Theme.Radius.l, topTrailingRadius: 0,
                    style: .continuous
                ))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(cornerRadius: Theme.Radius.l)
        // `glassSurface` only shapes the glass background; clip the card so the
        // full-bleed sparkline respects the rounded corners instead of poking out.
        .clipShape(.rect(cornerRadius: Theme.Radius.l, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { showDetail = true }
        .sheet(isPresented: $showDetail) {
            MetricDetailView(metric: metric, points: points)
        }
    }

    @ViewBuilder
    private var sparkline: some View {
        if recentPoints.count >= 2 {
            Chart {
                ForEach(recentPoints) { p in
                    LineMark(x: .value("Date", p.date), y: .value("Value", p.value))
                        .interpolationMethod(.linear)
                        .foregroundStyle(metric.accent)
                    AreaMark(x: .value("Date", p.date), y: .value("Value", p.value))
                        .interpolationMethod(.linear)
                        .foregroundStyle(metric.accent.opacity(0.12))
                }
                if let scrubbed {
                    RuleMark(x: .value("Scrub", scrubbed.date))
                        .foregroundStyle(.secondary.opacity(0.6))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            // Extra bottom buffer keeps the line floating above the card's lower
            // edge; the area still fills the gap beneath it.
            .chartYScale(domain: tightDomain(recentPoints, topPad: 0.15, bottomPad: 0.45))
            // `.monotone` can overshoot the data range and Charts does not clip
            // its plot to the frame by default — without this the area bleeds
            // far outside the small sparkline rect.
            .clipped()
            .chartScrubbing($scrubDate) { date in
                recentPoints.min(by: { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) })?.date
            }
        } else {
            // A single data point has no trend to draw — keep the card height
            // stable with a quiet baseline rather than an empty chart.
            Rectangle()
                .fill(.secondary.opacity(0.12))
                .frame(height: 1)
                .frame(maxHeight: .infinity, alignment: .center)
        }
    }
}

// MARK: - Detail view

/// The enlarged, time-range-adjustable chart shown when a metric card is tapped.
/// Filters the card's full history to the selected window and plots it with
/// axes, so the athlete can inspect the progression over a chosen period.
private struct MetricDetailView: View {
    let metric: PerformanceMetric
    let points: [MetricPoint]

    @Environment(\.dismiss) private var dismiss
    @State private var range: TimeRange = .threeMonths
    @State private var scrubDate: Date?

    /// The selectable windows over which the progression can be viewed.
    private enum TimeRange: String, CaseIterable, Identifiable {
        case oneMonth = "1M"
        case threeMonths = "3M"
        case sixMonths = "6M"
        case oneYear = "1Y"
        case all = "All"

        var id: String { rawValue }

        /// Cut-off date for the window, or `nil` for "All".
        func start(now: Date) -> Date? {
            let cal = Calendar.current
            switch self {
            case .oneMonth: return cal.date(byAdding: .month, value: -1, to: now)
            case .threeMonths: return cal.date(byAdding: .month, value: -3, to: now)
            case .sixMonths: return cal.date(byAdding: .month, value: -6, to: now)
            case .oneYear: return cal.date(byAdding: .year, value: -1, to: now)
            case .all: return nil
            }
        }
    }

    private var visiblePoints: [MetricPoint] {
        guard let start = range.start(now: Date()) else { return points }
        return points.filter { $0.date >= start }
    }

    private var trend: MetricTrend { MetricTrend(metric: metric, points: visiblePoints) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                    header
                    rangePicker
                    chart
                    stats
                }
                .padding(Theme.Spacing.l)
            }
            .navigationTitle(metric.title)
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Circle().fill(metric.accent).frame(width: 9, height: 9)
            Text(visiblePoints.last.map { metric.format($0.value) } ?? "—")
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

    private var rangePicker: some View {
        Picker("Range", selection: $range) {
            ForEach(TimeRange.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
    }

    @ViewBuilder
private var chart: some View {
        if visiblePoints.count >= 2 {
            Chart {
                ForEach(visiblePoints) { p in
                    LineMark(x: .value("Date", p.date), y: .value("Value", p.value))
                        .interpolationMethod(.linear)
                        .foregroundStyle(metric.accent)
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
                // y must fit *inside* the plot: `chartPlotStyle { $0.clipped() }`
                // clips the plot content, and an annotation overflowing above the
                // plot top (as the other, unclipped charts allow) is clipped away.
                .annotation(position: .top, spacing: 0,
                            overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .plot))) {
                    ChartTooltip(
                        title: p.date.formatted(.dateTime.day().month(.abbreviated).year()),
                        rows: [.init(color: metric.accent, label: metric.title,
                                     value: "\(metric.format(p.value)) \(metric.unit)")]
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
        .padding(Theme.Spacing.s)
        .glassSurface(cornerRadius: Theme.Radius.m)
    }
}
