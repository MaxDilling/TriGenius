import SwiftUI
import Charts

// MARK: - Fitness & Form detail
//
// The PMC on one time axis, like the ATP chart: Fitness and Fatigue as lines on the
// load scale, Form on its own scale on the right, centred so zero sits mid-plot,
// filled from zero and drawn beneath the load lines. The weekly ramp rate follows as
// its own chart. Dashed tails are the projection from planned workouts. Scrubbing the
// PMC moves the header readout.

struct PMCDetailView: View {
    let result: PMCResult
    @State var range: TimeRange
    @State private var planCurve: [PMCPoint] = []

    var body: some View {
        let weeks = range.weeks(first: result.points.first?.date)
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                PMCPanel(result: result, range: range)
                RampRateChart(model: RampRateModel(
                    weeks: RampRate.weeklySeries(points: result.points, weeks: weeks),
                    planned: RampRate.weeklySeries(points: planCurve, weeks: weeks)))
                    .cardTitle("Ramp rate · CTL per week")
                    .contentCard()
                SectionHeading("About Fitness & Form")
                Text("Fitness (CTL) is your 42-day weighted average training load, Fatigue (ATL) the 7-day one. Form (TSB) is fitness minus fatigue: negative while you build, positive once you are fresh — it reads on the right-hand scale, with zero in the middle. Dashed lines are projected from your planned workouts. The ramp rate is how much fitness changes per week, the plan's in grey behind it — the shaded band marks a sustainable build.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .contentCard()
            }
            .padding(Theme.Spacing.l)
        }
        .background(Color.appBackground)
        .navigationTitle("Fitness & Form")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .rangeToolbar($range)
        .task { planCurve = ATPEngine.current()?.planCurve ?? [] }
    }
}

/// The readout and the PMC chart. Owns the scrub, so a scrub step re-renders only
/// this panel, against series and scales cut once per range.
private struct PMCPanel: View {
    let points: [PMCPoint]
    /// Forecast prefixed with the last historic point, so the dashed continuation
    /// joins the solid curve at "today".
    let forecastLine: [PMCPoint]
    let allPoints: [PMCPoint]
    /// Top of the load scale, rounded up to the next 10 above the highest CTL / ATL.
    let loadMax: Double
    /// Largest |TSB| the Form scale spans each way from its middle zero, floored so a
    /// near-flat curve isn't blown up.
    let formMax: Double

    @State private var scrubDate: Date?

    init(result: PMCResult, range: TimeRange) {
        points = result.points.filter { range.contains($0.date) }
        forecastLine = result.forecast.isEmpty ? [] : points.last.map { [$0] + result.forecast } ?? []
        allPoints = points + result.forecast
        let loadPeak = allPoints.map { max($0.ctl, $0.atl) }.max() ?? 0
        loadMax = max((loadPeak * 1.1 / 10).rounded(.up) * 10, 10)
        let formPeak = allPoints.map { abs($0.tsb) }.max() ?? 0
        formMax = max((formPeak * 1.1 / 10).rounded(.up) * 10, 20)
    }

    private func formY(_ tsb: Double) -> Double { loadMax / 2 * (1 + tsb / formMax) }
    private func tsb(atY y: Double) -> Double { (y / (loadMax / 2) - 1) * formMax }

    private func isForecast(_ p: PMCPoint) -> Bool { p.date > (points.last?.date ?? .distantFuture) }

    private func nearestPoint(to date: Date) -> PMCPoint? {
        allPoints.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
    }

    var body: some View {
        if let p = scrubDate.flatMap(nearestPoint) ?? points.last { readout(p) }
        chart.cardTitle("Fitness, Fatigue & Form").contentCard()
    }

    /// Health-style header: the three values at the scrubbed day, else today.
    private func readout(_ p: PMCPoint) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack(spacing: Theme.Spacing.m) {
                value("Fitness", Theme.Palette.fitness, p.ctl)
                Divider()
                value("Fatigue", Theme.Palette.fatigue, p.atl)
                Divider()
                value("Form", Theme.Palette.form, p.tsb)
            }
            .fixedSize(horizontal: false, vertical: true)
            Text(p.date.formatted(.dateTime.day().month(.abbreviated).year()) + (isForecast(p) ? " · projected" : ""))
                .font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private func value(_ label: String, _ color: Color, _ value: Double) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(color)
            Text("\(Int(value.rounded()))").font(.title.bold()).monospacedDigit()
        }
    }

    // MARK: Chart

    /// Declared back to front — Charts draws later series on top.
    private var chart: some View {
        let form = Theme.Palette.form.opacity(0.6)
        return Chart {
            RuleMark(y: .value("Form zero", formY(0)))
                .foregroundStyle(form.opacity(0.4))
                .lineStyle(StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
            ForEach(allPoints) { p in
                AreaMark(x: .value("Date", p.date),
                         yStart: .value("Form zero", formY(0)), yEnd: .value("Form", formY(p.tsb)))
                    .foregroundStyle(Theme.Palette.form.opacity(0.08))
            }
            series("Form", form) { formY($0.tsb) }
            series("Fatigue", Theme.Palette.fatigue) { $0.atl }
            series("Fitness", Theme.Palette.fitness) { $0.ctl }
            if let date = scrubDate {
                RuleMark(x: .value("Scrub", date))
                    .foregroundStyle(.secondary.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1))
            }
        }
        .chartXScale(domain: (allPoints.first?.date ?? Date())...(allPoints.last?.date ?? Date()))
        .chartYScale(domain: 0...loadMax)
        .chartYAxis {
            AxisMarks(position: .leading)
            AxisMarks(position: .trailing, values: [-1, -0.5, 0, 0.5, 1].map { formY($0 * formMax) }) { value in
                AxisTick()
                AxisValueLabel {
                    if let y = value.as(Double.self) {
                        Text("\(Int(tsb(atY: y).rounded()))").foregroundStyle(Theme.Palette.form)
                    }
                }
            }
        }
        .chartScrubbing($scrubDate) { nearestPoint(to: $0)?.date }
        .frame(height: 260)
    }

    /// One PMC series: solid through today, dashed and faded over the projection.
    @ChartContentBuilder
    private func series(_ name: String, _ color: Color, _ y: @escaping (PMCPoint) -> Double) -> some ChartContent {
        ForEach(points) { line($0.date, y($0), name, color) }
        ForEach(forecastLine) { line($0.date, y($0), name + " (proj)", color.opacity(0.45), dash: [4, 3]) }
    }

    private func line(_ date: Date, _ value: Double, _ series: String,
                      _ color: Color, dash: [CGFloat] = []) -> some ChartContent {
        LineMark(x: .value("Date", date), y: .value(series, value),
                 series: .value("Series", series))
            .foregroundStyle(color)
            .lineStyle(StrokeStyle(lineWidth: 2, dash: dash))
    }
}
