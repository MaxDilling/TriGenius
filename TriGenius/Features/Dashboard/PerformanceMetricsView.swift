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
/// everything needed to read, format and color it.
private struct PerformanceMetric: Identifiable {
    /// snake_case metric key stored in the DB (see `TrainingDataStore.ingestMetrics`).
    let key: String
    let title: String
    let accent: Color
    /// Label shown under the value (e.g. "W", "ml/kg/min", "/km").
    let unit: String
    /// Renders a raw stored value as a display string.
    let format: (Double) -> String
    /// True when a rising value is an improvement (VO2max, FTP); false for the
    /// pace markers where a lower value (faster) is better.
    let higherIsBetter: Bool

    var id: String { key }

    /// The markers shown, in priority order. Pace values are stored in seconds
    /// and rendered as "m:ss" (matching `PerformanceSnapshot`).
    static let all: [PerformanceMetric] = [
        PerformanceMetric(key: "vo2max_running", title: "VO₂max (Run)", accent: .red,
                          unit: "ml/kg/min", format: intFormat, higherIsBetter: true),
        PerformanceMetric(key: "vo2max_cycling", title: "VO₂max (Bike)", accent: .orange,
                          unit: "ml/kg/min", format: intFormat, higherIsBetter: true),
        PerformanceMetric(key: "cycling_ftp", title: "FTP (Bike)", accent: .blue,
                          unit: "W", format: intFormat, higherIsBetter: true),
        PerformanceMetric(key: "running_ftp", title: "FTP (Run)", accent: .indigo,
                          unit: "W", format: intFormat, higherIsBetter: true),
        PerformanceMetric(key: "lactate_threshold_hr", title: "LT Heart Rate", accent: .pink,
                          unit: "bpm", format: intFormat, higherIsBetter: true),
        PerformanceMetric(key: "lactate_threshold_pace", title: "LT Pace", accent: .teal,
                          unit: "/km", format: paceFormat, higherIsBetter: false),
        PerformanceMetric(key: "swim_css_pace", title: "CSS (Swim)", accent: .cyan,
                          unit: "/100m", format: paceFormat, higherIsBetter: false),
        PerformanceMetric(key: "max_hr", title: "Max Heart Rate", accent: .purple,
                          unit: "bpm", format: intFormat, higherIsBetter: true),
    ]

    private static let intFormat: (Double) -> String = { String(Int($0.rounded())) }
    private static let paceFormat: (Double) -> String = { secs in
        guard secs > 0 else { return "—" }
        return String(format: "%d:%02d", Int(secs) / 60, Int(secs) % 60)
    }
}

// MARK: - Section

/// The grid of physiological-marker cards on the Performance Insights screen.
/// Reads each marker's history from the store on appear; renders nothing when
/// no marker has any data yet.
struct PerformanceMetricsSection: View {
    @State private var histories: [String: [MetricPoint]] = [:]
    @State private var loaded = false

    private var available: [PerformanceMetric] {
        PerformanceMetric.all.filter { (histories[$0.key]?.isEmpty == false) }
    }

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 10)]

    var body: some View {
        // A concrete VStack (not a transparent `Group`) so the `.task` loader
        // fires reliably even while the section has nothing to show yet.
        VStack(alignment: .leading, spacing: 12) {
            Text("Performance Metrics").font(.headline)
            if !available.isEmpty {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(available) { metric in
                        MetricCard(metric: metric, points: histories[metric.key] ?? [])
                    }
                }
            } else if loaded {
                Text("No performance metrics yet. VO₂max, FTP and your threshold values appear here once your data source reports them.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.Spacing.m)
                    .glassSurface(cornerRadius: Theme.Radius.l)
            }
        }
        .task { load() }
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

// MARK: - Card

private struct MetricCard: View {
    let metric: PerformanceMetric
    let points: [MetricPoint]

    /// Change between the first and latest stored value (raw units).
    private var rawDelta: Double {
        guard let first = points.first?.value, let last = points.last?.value else { return 0 }
        return last - first
    }

    /// True when the latest value is an improvement over the first.
    private var isImproved: Bool {
        metric.higherIsBetter ? rawDelta > 0 : rawDelta < 0
    }

    private var deltaText: String? {
        guard abs(rawDelta) >= 0.5 else { return nil }
        return metric.format(abs(rawDelta))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Circle().fill(metric.accent).frame(width: 7, height: 7)
                Text(metric.title).font(.caption).foregroundStyle(.secondary)
            }

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(points.last.map { metric.format($0.value) } ?? "—")
                    .font(.title2.bold())
                Text(metric.unit).font(.caption2).foregroundStyle(.secondary)
                Spacer()
                if let deltaText {
                    HStack(spacing: 1) {
                        Image(systemName: rawDelta > 0 ? "arrow.up" : "arrow.down")
                        Text(deltaText)
                    }
                    .font(.caption2)
                    .foregroundStyle(isImproved ? Theme.Palette.success : Theme.Palette.warning)
                }
            }

            sparkline
                .frame(height: 32)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Spacing.m)
        .glassSurface(cornerRadius: Theme.Radius.l)
    }

    @ViewBuilder
    private var sparkline: some View {
        if points.count >= 2 {
            Chart(points) { p in
                LineMark(x: .value("Date", p.date), y: .value("Value", p.value))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(metric.accent)
                AreaMark(x: .value("Date", p.date), y: .value("Value", p.value))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(metric.accent.opacity(0.12))
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartYScale(domain: .automatic(includesZero: false))
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
