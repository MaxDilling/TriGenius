import SwiftUI
import Charts

// MARK: - Performance Insights (PMC detail)
//
// The screen behind the dashboard's "Details" link. Shows the CTL / ATL / TSB
// summary plus the full Performance Management Chart over a selectable range:
// CTL (Fitness) and ATL (Fatigue) as lines, TSB (Form) as signed bars
// (green = positive/fresh, orange = negative/fatigued).

struct PerformanceInsightsView: View {
    let result: PMCResult

    @State private var range: PMCRange = .thirty

    private var points: [PMCPoint] {
        guard let last = result.points.last else { return [] }
        let cal = Calendar.current
        guard let cutoff = cal.date(byAdding: .day, value: -range.days, to: last.date) else {
            return result.points
        }
        return result.points.filter { $0.date >= cutoff }
    }

    /// The forward projection (always future, so always within the trailing range).
    private var forecastPoints: [PMCPoint] { result.forecast }

    /// Forecast line series prefixed with the last historic point so the dashed
    /// continuation visually joins the solid curve at "today".
    private var forecastLine: [PMCPoint] {
        guard !forecastPoints.isEmpty, let connector = points.last else { return [] }
        return [connector] + forecastPoints
    }

    /// Every point the chart draws — used so the axes leave room for the forecast.
    private var allPoints: [PMCPoint] { points + forecastPoints }

    // MARK: Dual-axis scaling
    //
    // Swift Charts has no native secondary Y-axis, so Form (TSB) is plotted in the
    // CTL/ATL coordinate space: its symmetric domain [-tsbMax, tsbMax] is mapped onto
    // the line domain [0, lineMax] so that TSB = 0 lands exactly in the vertical
    // middle. A trailing axis re-labels those positions with the real TSB values.

    /// Top of the CTL/ATL (left) axis, with a little headroom.
    private var lineMax: Double {
        let m = allPoints.flatMap { [$0.ctl, $0.atl] }.max() ?? 1
        return max((m * 1.1 / 10).rounded(.up) * 10, 10)
    }

    /// Symmetric half-range of the Form (right) axis, rounded to a nice value.
    private var tsbMax: Double {
        let m = allPoints.map { abs($0.tsb) }.max() ?? 10
        return max((m * 1.1 / 10).rounded(.up) * 10, 10)
    }

    /// Maps a TSB value into the line coordinate space (0 → middle of the chart).
    private func scaleTSB(_ tsb: Double) -> Double {
        (tsb + tsbMax) / (2 * tsbMax) * lineMax
    }

    /// Inverse of `scaleTSB`, used to label the trailing axis with real TSB values.
    private func unscaleTSB(_ scaled: Double) -> Double {
        scaled / lineMax * 2 * tsbMax - tsbMax
    }

    /// Scaled Y position of the Form = 0 baseline (the vertical middle).
    private var tsbZero: Double { lineMax / 2 }

    /// Symmetric TSB tick values for the trailing axis.
    private var tsbTicks: [Double] {
        [-tsbMax, -tsbMax / 2, 0, tsbMax / 2, tsbMax]
    }

    var body: some View {
        ScrollView {
            // One GlassEffectContainer so the stat cards and chart pane blend as a
            // single glass system instead of stacking independent glass layers.
            GlassEffectContainer(spacing: Theme.Spacing.l) {
                VStack(spacing: 20) {
                    if let s = result.snapshot {
                        HStack(spacing: 10) {
                            statCard("Fitness", dot: .blue, value: Int(s.ctl.rounded()),
                                     delta: delta { $0.ctl })
                            statCard("Fatigue", dot: .pink, value: Int(s.atl.rounded()),
                                     delta: delta { $0.atl })
                            statCard("Form", dot: .orange, value: Int(s.tsb.rounded()),
                                     delta: delta { $0.tsb })
                        }
                    }

                    chartCard

                    PerformanceMetricsSection()
                }
            }
            .padding()
        }
        .navigationTitle("Performance Insights")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    // MARK: Chart marks
    //
    // Split into per-series @ChartContentBuilder properties: a single Chart {} with
    // this many marks overwhelms the type-checker (Swift Charts builders infer deep
    // generic types), so the historic and projected layers are built separately.

    @ChartContentBuilder private var historicMarks: some ChartContent {
        // Form (TSB) bars, drawn from the centered zero baseline.
        ForEach(points) { p in
            BarMark(
                x: .value("Date", p.date),
                yStart: .value("Form", tsbZero),
                yEnd: .value("Form", scaleTSB(p.tsb))
            )
            .foregroundStyle(p.tsb >= 0 ? Color.green.opacity(0.6) : Color.orange.opacity(0.6))
        }
        // Dashed baseline marking Form = 0 in the vertical middle.
        RuleMark(y: .value("Form zero", tsbZero))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            .foregroundStyle(.secondary.opacity(0.4))

        ForEach(points) { p in
            LineMark(
                x: .value("Date", p.date),
                y: .value("Fitness", p.ctl),
                series: .value("Series", "Fitness")
            )
            .foregroundStyle(.blue)
            LineMark(
                x: .value("Date", p.date),
                y: .value("Fatigue", p.atl),
                series: .value("Series", "Fatigue")
            )
            .foregroundStyle(.pink)
        }
    }

    /// Forward projection (planned-but-not-yet-completed workouts), drawn as a
    /// faded dashed continuation joined to the historic curve at "today".
    @ChartContentBuilder private var forecastMarks: some ChartContent {
        ForEach(forecastPoints) { p in
            BarMark(
                x: .value("Date", p.date),
                yStart: .value("Form", tsbZero),
                yEnd: .value("Form", scaleTSB(p.tsb))
            )
            .foregroundStyle((p.tsb >= 0 ? Color.green : Color.orange).opacity(0.22))
        }
        ForEach(forecastLine) { p in
            LineMark(
                x: .value("Date", p.date),
                y: .value("Fitness", p.ctl),
                series: .value("Series", "Fitness (proj)")
            )
            .foregroundStyle(.blue.opacity(0.45))
            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            LineMark(
                x: .value("Date", p.date),
                y: .value("Fatigue", p.atl),
                series: .value("Series", "Fatigue (proj)")
            )
            .foregroundStyle(.pink.opacity(0.45))
            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
        }
    }

    // MARK: Chart

    private var chartCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("PMC Chart").font(.headline)
                Spacer()
                Picker("Range", selection: $range) {
                    ForEach(PMCRange.allCases) { r in Text(r.label).tag(r) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }

            Chart {
                historicMarks
                forecastMarks
            }
            .chartYScale(domain: 0...lineMax)
            .chartYAxis {
                // Left axis: CTL / ATL.
                AxisMarks(position: .leading)
                // Right axis: Form (TSB), re-labeled with real values, 0 centered.
                AxisMarks(position: .trailing, values: tsbTicks.map(scaleTSB)) { value in
                    AxisTick()
                    AxisValueLabel {
                        if let scaled = value.as(Double.self) {
                            Text("\(Int(unscaleTSB(scaled).rounded()))")
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
            .frame(height: 260)
            .chartLegend(.hidden)

            HStack(spacing: 16) {
                legend(.blue, "Fitness (CTL)")
                legend(.pink, "Fatigue (ATL)")
                legend(.green, "Form (TSB, right)")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            if !forecastPoints.isEmpty {
                Label("Dashed = projected from planned workouts", systemImage: "chart.line.flattrend.xyaxis")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Spacing.l)
        .glassSurface(cornerRadius: Theme.Radius.l)
    }

    private func legend(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label)
        }
    }

    private func statCard(_ title: String, dot: Color, value: Int, delta: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Circle().fill(dot).frame(width: 7, height: 7)
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(value)").font(.title.bold())
                if delta != 0 {
                    HStack(spacing: 1) {
                        Image(systemName: delta > 0 ? "arrow.up" : "arrow.down")
                        Text("\(abs(delta))")
                    }
                    .font(.caption2).foregroundStyle(dot)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Spacing.m)
        .glassSurface(cornerRadius: Theme.Radius.l)
    }

    private func delta(_ metric: (PMCPoint) -> Double) -> Int {
        guard let now = result.points.last.map(metric),
              let then = result.value(daysAgo: 7, metric) else { return 0 }
        return Int((now - then).rounded())
    }
}

// MARK: - Range

enum PMCRange: String, CaseIterable, Identifiable {
    case thirty
    case ninety
    case year

    var id: String { rawValue }
    var label: String {
        switch self {
        case .thirty: return "30D"
        case .ninety: return "90D"
        case .year:   return "1Y"
        }
    }
    var days: Int {
        switch self {
        case .thirty: return 30
        case .ninety: return 90
        case .year:   return 365
        }
    }
}
