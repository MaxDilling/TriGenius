import SwiftUI
import Charts

// MARK: - CTL trend chart
//
// Actual fitness (CTL) against the ATP's planned CTL around today: the planned
// curve is a solid grey background line spanning the whole window, the actual
// line ends at today and continues dashed over the next week as the PMC's
// projection from the scheduled workouts. An empty `planned` (no ATP) or
// `forecast` (nothing scheduled) simply drops that layer.

struct CTLPoint: Codable, Equatable, Identifiable {
    var date: Date
    var ctl: Double
    var id: Date { date }
}

struct CTLTrendModel: Codable, Equatable {
    var actual: [CTLPoint]    // daily actual CTL, window start … today
    var planned: [CTLPoint]   // ATP plan curve across the full window
    var forecast: [CTLPoint] = []   // projected CTL, tomorrow … 7 days ahead

    /// Actual CTL from `start` (default: 15 days back) up to today, its projection
    /// over the next 7 days, the plan curve from `start` to 15 days ahead.
    @MainActor
    static func around(pmc: PMCResult, planCurve: [PMCPoint],
                       from start: Date? = nil, today: Date = Date()) -> CTLTrendModel {
        let cal = Calendar.current
        let day = cal.startOfDay(for: today)
        let start = start ?? cal.date(byAdding: .day, value: -15, to: day) ?? day
        let end = cal.date(byAdding: .day, value: 15, to: day) ?? day
        let forecastEnd = cal.date(byAdding: .day, value: 7, to: day) ?? day
        func ctl(_ p: PMCPoint) -> CTLPoint { CTLPoint(date: p.date, ctl: p.ctl) }
        return CTLTrendModel(
            actual: pmc.points.filter { $0.date >= start }.map(ctl),
            planned: planCurve.filter { $0.date >= start && $0.date <= end }.map(ctl),
            forecast: pmc.forecast.filter { $0.date <= forecastEnd }.map(ctl)
        )
    }
}

struct CTLTrendChart: View {
    let model: CTLTrendModel

    @State private var scrubDate: Date?

    var body: some View {
        Chart {
            ForEach(model.planned) { p in
                LineMark(x: .value("Date", p.date), y: .value("Plan", p.ctl), series: .value("Series", "Plan"))
                    .foregroundStyle(Theme.Palette.plan.opacity(0.45))
                    .lineStyle(StrokeStyle(lineWidth: 3))
            }
            ForEach(model.actual) { p in
                LineMark(x: .value("Date", p.date), y: .value("CTL", p.ctl), series: .value("Series", "Actual"))
                    .foregroundStyle(Theme.Palette.fitness)
                    .lineStyle(StrokeStyle(lineWidth: 2))
            }
            ForEach(model.forecast.isEmpty ? [] : model.actual.suffix(1) + model.forecast) { p in
                LineMark(x: .value("Date", p.date), y: .value("CTL", p.ctl), series: .value("Series", "Forecast"))
                    .foregroundStyle(Theme.Palette.fitness.opacity(0.45))
                    .lineStyle(StrokeStyle(lineWidth: 2, dash: [4, 3]))
            }
            RuleMark(x: .value("Today", Calendar.current.startOfDay(for: Date())))
                .foregroundStyle(.secondary.opacity(0.4))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            scrubMarks
        }
        .chartYScale(domain: yDomain)
        .frame(height: 160)
        .chartScrubbing($scrubDate) { nearestDay(to: $0) }
    }

    @ChartContentBuilder private var scrubMarks: some ChartContent {
        if let date = scrubDate, let day = nearestDay(to: date) {
            RuleMark(x: .value("Scrub", day))
                .foregroundStyle(.secondary.opacity(0.6))
                .lineStyle(StrokeStyle(lineWidth: 1))
                .annotation(position: .top, spacing: 0,
                            overflowResolution: .init(x: .fit(to: .plot), y: .fit(to: .plot))) {
                    tooltip(for: day)
                }
        }
    }

    private func tooltip(for day: Date) -> ChartTooltip {
        var rows: [ChartTooltip.Row] = []
        if let actual = value(in: model.actual, on: day) {
            rows.append(.init(color: Theme.Palette.fitness, label: "Fitness",
                              value: actual.formatted(.number.precision(.fractionLength(1)))))
        }
        if let projected = value(in: model.forecast, on: day) {
            rows.append(.init(color: Theme.Palette.fitness.opacity(0.45), label: "Projected",
                              value: projected.formatted(.number.precision(.fractionLength(1)))))
        }
        if let plan = value(in: model.planned, on: day) {
            rows.append(.init(color: Theme.Palette.plan, label: "Plan",
                              value: plan.formatted(.number.precision(.fractionLength(1)))))
        }
        return ChartTooltip(title: day.formatted(.dateTime.day().month(.abbreviated)), rows: rows)
    }

    /// The drawn day closest to the scrubbed date, so the rule snaps to data.
    private func nearestDay(to date: Date) -> Date? {
        (model.actual + model.forecast + model.planned).map(\.date)
            .min { abs($0.timeIntervalSince(date)) < abs($1.timeIntervalSince(date)) }
    }

    private func value(in points: [CTLPoint], on day: Date) -> Double? {
        points.first { Calendar.current.isDate($0.date, inSameDayAs: day) }?.ctl
    }

    /// Tightened Y-range: CTL moves a few points over ±15 days, so a zero-anchored
    /// axis would flatten both curves into indistinguishable lines.
    private var yDomain: ClosedRange<Double> {
        let values = (model.actual + model.forecast + model.planned).map(\.ctl)
        guard let min = values.min(), let max = values.max() else { return 0...1 }
        let pad = Swift.max(2, (max - min) * 0.2)
        return (min - pad)...(max + pad)
    }
}
