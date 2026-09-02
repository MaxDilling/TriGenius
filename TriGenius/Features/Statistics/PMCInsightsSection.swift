import SwiftUI
import Charts

// MARK: - PMC insights section
//
// The CTL / ATL / TSB stat cards plus the full Performance Management Chart at the
// top of the Statistics screen: CTL (Fitness) and ATL (Fatigue) as lines, TSB
// (Form) as signed bars (green = positive/fresh, orange = negative/fatigued).
// `days` is the screen-wide range — the section owns no range control of its own.

struct PMCInsightsSection: View {
    let result: PMCResult
    let days: Int

    @State private var scrubDate: Date?
    private var wide = WideLayout()

    private var points: [PMCPoint] {
        guard let last = result.points.last else { return [] }
        let cal = Calendar.current
        guard let cutoff = cal.date(byAdding: .day, value: -days, to: last.date) else {
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
        wide.outer {
            PMCStatTiles(result: result)
            chartCard
        }
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
            .foregroundStyle((p.tsb >= 0 ? Theme.Palette.success : Theme.Palette.warning).opacity(0.6))
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
            .foregroundStyle(Theme.Palette.fitness)
            LineMark(
                x: .value("Date", p.date),
                y: .value("Fatigue", p.atl),
                series: .value("Series", "Fatigue")
            )
            .foregroundStyle(Theme.Palette.fatigue)
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
            .foregroundStyle((p.tsb >= 0 ? Theme.Palette.success : Theme.Palette.warning).opacity(0.22))
        }
        ForEach(forecastLine) { p in
            LineMark(
                x: .value("Date", p.date),
                y: .value("Fitness", p.ctl),
                series: .value("Series", "Fitness (proj)")
            )
            .foregroundStyle(Theme.Palette.fitness.opacity(0.45))
            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            LineMark(
                x: .value("Date", p.date),
                y: .value("Fatigue", p.atl),
                series: .value("Series", "Fatigue (proj)")
            )
            .foregroundStyle(Theme.Palette.fatigue.opacity(0.45))
            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
        }
    }

    /// Scrub readout: the rule + tooltip at the selected day, values from the
    /// historic or forecast point on that day.
    @ChartContentBuilder private var scrubMarks: some ChartContent {
        if let date = scrubDate, let p = nearestPoint(to: date) {
            RuleMark(x: .value("Scrub", p.date))
                .foregroundStyle(.secondary.opacity(0.6))
                .lineStyle(StrokeStyle(lineWidth: 1))
                .annotation(position: .top, spacing: 0,
                            overflowResolution: .init(x: .fit(to: .plot), y: .fit(to: .plot))) {
                    ChartTooltip(
                        title: p.date.formatted(.dateTime.day().month(.abbreviated)),
                        rows: [
                            .init(color: Theme.Palette.fitness, label: "Fitness", value: "\(Int(p.ctl.rounded()))"),
                            .init(color: Theme.Palette.fatigue, label: "Fatigue", value: "\(Int(p.atl.rounded()))"),
                            .init(color: Theme.Palette.form, label: "Form", value: "\(Int(p.tsb.rounded()))"),
                        ]
                    )
                }
        }
    }

    private func nearestPoint(to date: Date) -> PMCPoint? {
        allPoints.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
    }

    // MARK: Chart

    private var chartCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Chart {
                historicMarks
                forecastMarks
                scrubMarks
            }
            .chartScrubbing($scrubDate) { nearestPoint(to: $0)?.date }
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
                                .foregroundStyle(Theme.Palette.form)
                        }
                    }
                }
            }
            .frame(minHeight: 260, maxHeight: wide.isWide ? .infinity : 260)
            .chartLegend(.hidden)

            legendLayout {
                HStack(spacing: 16) {
                    legend(Theme.Palette.fitness, "Fitness (CTL)")
                    legend(Theme.Palette.fatigue, "Fatigue (ATL)")
                    legend(Theme.Palette.form, "Form (TSB)")
                }
                .foregroundStyle(.secondary)

                if !forecastPoints.isEmpty {
                    Label("Dashed = projected from planned workouts", systemImage: "chart.line.flattrend.xyaxis")
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.caption2)
        }
        .glassCard()
        .frame(maxHeight: wide.rowHeight)
    }

    /// The series legend and the dashed-forecast note share a line where the card
    /// is wide enough, and stack under it on the phone.
    private var legendLayout: AnyLayout {
        wide.isWide ? AnyLayout(HStackLayout(spacing: Theme.Spacing.l))
                    : AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
    }

    private func legend(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label)
        }
    }
}
