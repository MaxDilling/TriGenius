import SwiftUI
import Charts

// MARK: - Fitness & Form detail
//
// The PMC as small multiples on one time axis — Fitness and Fatigue as lines, Form
// as bars around zero, the weekly ramp rate below — each on its own true scale.
// The dashed / faded tail is the projection from planned workouts. Scrubbing the
// upper panels moves the header readout.

struct PMCDetailView: View {
    let result: PMCResult
    @State var range: TimeRange
    @State private var scrubDate: Date?

    private var points: [PMCPoint] { result.points.filter { range.contains($0.date) } }

    /// Forecast line prefixed with the last historic point, so the dashed
    /// continuation joins the solid curve at "today".
    private var forecastLine: [PMCPoint] {
        guard !result.forecast.isEmpty, let today = points.last else { return [] }
        return [today] + result.forecast
    }

    private var allPoints: [PMCPoint] { points + result.forecast }

    private var xDomain: ClosedRange<Date> {
        (allPoints.first?.date ?? Date())...(allPoints.last?.date ?? Date())
    }

    private func isForecast(_ p: PMCPoint) -> Bool { p.date > (points.last?.date ?? .distantFuture) }

    private func nearestPoint(to date: Date) -> PMCPoint? {
        allPoints.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                if let p = scrubDate.flatMap(nearestPoint) ?? points.last { readout(p) }
                panel("Fitness & Fatigue") { loadChart }
                panel("Form") { formChart }
                panel("Ramp rate · CTL per week") {
                    RampRateChart(model: RampRateModel(
                        weeks: RampRate.weeklySeries(points: result.points, weeks: range.weeks(first: result.points.first?.date)),
                        safeBand: RampRate.safeBand))
                }
                if !result.forecast.isEmpty {
                    Label("Dashed = projected from planned workouts", systemImage: "chart.line.flattrend.xyaxis")
                        .font(.caption).foregroundStyle(.secondary)
                }
                SectionHeading("About Fitness & Form")
                Text("Fitness (CTL) is your 42-day weighted average training load, Fatigue (ATL) the 7-day one. Form (TSB) is fitness minus fatigue: negative while you build, positive once you are fresh. The ramp rate is how much fitness changes per week — the shaded band marks a sustainable build.")
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
    }

    /// Health-style header: the three values at the scrubbed day, else today.
    private func readout(_ p: PMCPoint) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack(spacing: Theme.Spacing.xl) {
                value("Fitness", Theme.Palette.fitness, p.ctl)
                value("Fatigue", Theme.Palette.fatigue, p.atl)
                value("Form", Theme.Palette.form, p.tsb)
            }
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

    private func panel(_ title: String, @ViewBuilder chart: () -> some View) -> some View {
        chart().cardTitle(title).contentCard()
    }

    // MARK: Charts

    private var loadChart: some View {
        Chart {
            ForEach(points) { p in
                line(p, \.ctl, "Fitness", Theme.Palette.fitness)
                line(p, \.atl, "Fatigue", Theme.Palette.fatigue)
            }
            ForEach(forecastLine) { p in
                line(p, \.ctl, "Fitness (proj)", Theme.Palette.fitness.opacity(0.45), dash: [4, 3])
                line(p, \.atl, "Fatigue (proj)", Theme.Palette.fatigue.opacity(0.45), dash: [4, 3])
            }
            scrubRule
        }
        .panelAxis(xDomain, scrub: $scrubDate) { nearestPoint(to: $0)?.date }
    }

    private var formChart: some View {
        Chart {
            ForEach(allPoints) { p in
                BarMark(x: .value("Date", p.date, unit: .day), y: .value("Form", p.tsb))
                    .foregroundStyle((p.tsb >= 0 ? Theme.Palette.success : Theme.Palette.warning)
                        .opacity(isForecast(p) ? 0.22 : 0.6))
            }
            RuleMark(y: .value("Zero", 0))
                .foregroundStyle(.secondary.opacity(0.4))
            scrubRule
        }
        .panelAxis(xDomain, scrub: $scrubDate) { nearestPoint(to: $0)?.date }
    }

    private func line(_ p: PMCPoint, _ metric: KeyPath<PMCPoint, Double>, _ series: String,
                      _ color: Color, dash: [CGFloat] = []) -> some ChartContent {
        LineMark(x: .value("Date", p.date), y: .value(series, p[keyPath: metric]),
                 series: .value("Series", series))
            .foregroundStyle(color)
            .lineStyle(StrokeStyle(lineWidth: 2, dash: dash))
    }

    @ChartContentBuilder private var scrubRule: some ChartContent {
        if let date = scrubDate {
            RuleMark(x: .value("Scrub", date))
                .foregroundStyle(.secondary.opacity(0.6))
                .lineStyle(StrokeStyle(lineWidth: 1))
        }
    }
}

private extension View {
    /// The shared time axis and scrub of the upper panels.
    func panelAxis(_ domain: ClosedRange<Date>, scrub: Binding<Date?>,
                   snap: @escaping (Date) -> Date?) -> some View {
        chartXScale(domain: domain)
            .chartScrubbing(scrub, snap: snap)
            .frame(height: 180)
    }
}
