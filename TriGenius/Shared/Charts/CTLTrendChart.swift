import SwiftUI
import Charts

// MARK: - CTL trend chart
//
// Actual fitness (CTL) against the ATP's planned CTL around today: the planned
// curve is a solid grey background line spanning the whole window, the actual
// line ends at today (no forecast fabrication). An empty `planned` (no ATP)
// simply drops that layer.

struct CTLPoint: Codable, Equatable, Identifiable {
    var date: Date
    var ctl: Double
    var id: Date { date }
}

struct CTLTrendModel: Codable, Equatable {
    var actual: [CTLPoint]    // daily actual CTL, window start … today
    var planned: [CTLPoint]   // ATP plan curve across the full window

    /// The ±window around today: actual CTL up to today, plan curve across it.
    @MainActor
    static func around(points: [PMCPoint], planCurve: [PMCPoint],
                       today: Date = Date(), daysBack: Int = 15, daysForward: Int = 15) -> CTLTrendModel {
        let cal = Calendar.current
        let day = cal.startOfDay(for: today)
        let start = cal.date(byAdding: .day, value: -daysBack, to: day) ?? day
        let end = cal.date(byAdding: .day, value: daysForward, to: day) ?? day
        return CTLTrendModel(
            actual: points.filter { $0.date >= start }.map { CTLPoint(date: $0.date, ctl: $0.ctl) },
            planned: planCurve.filter { $0.date >= start && $0.date <= end }
                .map { CTLPoint(date: $0.date, ctl: $0.ctl) }
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
                    .foregroundStyle(Color.gray.opacity(0.45))
                    .lineStyle(StrokeStyle(lineWidth: 3))
            }
            ForEach(model.actual) { p in
                LineMark(x: .value("Date", p.date), y: .value("CTL", p.ctl), series: .value("Series", "Actual"))
                    .foregroundStyle(Theme.Palette.info)
                    .lineStyle(StrokeStyle(lineWidth: 2))
            }
            RuleMark(x: .value("Today", Calendar.current.startOfDay(for: Date())))
                .foregroundStyle(.secondary.opacity(0.4))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            scrubMarks
        }
        .chartYScale(domain: yDomain)
        .frame(height: 160)
        .chartDateScrubbing($scrubDate) { nearestDay(to: $0) }
    }

    @ChartContentBuilder private var scrubMarks: some ChartContent {
        if let date = scrubDate, let day = nearestDay(to: date) {
            RuleMark(x: .value("Scrub", day))
                .foregroundStyle(.secondary.opacity(0.6))
                .lineStyle(StrokeStyle(lineWidth: 1))
                .annotation(position: .top, spacing: 0,
                            overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                    tooltip(for: day)
                }
        }
    }

    private func tooltip(for day: Date) -> ChartTooltip {
        var rows: [ChartTooltip.Row] = []
        if let actual = value(in: model.actual, on: day) {
            rows.append(.init(color: Theme.Palette.info, label: "Fitness",
                              value: actual.formatted(.number.precision(.fractionLength(1)))))
        }
        if let plan = value(in: model.planned, on: day) {
            rows.append(.init(color: .gray, label: "Plan",
                              value: plan.formatted(.number.precision(.fractionLength(1)))))
        }
        return ChartTooltip(title: day.formatted(.dateTime.day().month(.abbreviated)), rows: rows)
    }

    /// The drawn day closest to the scrubbed date, so the rule snaps to data.
    private func nearestDay(to date: Date) -> Date? {
        (model.actual + model.planned).map(\.date)
            .min { abs($0.timeIntervalSince(date)) < abs($1.timeIntervalSince(date)) }
    }

    private func value(in points: [CTLPoint], on day: Date) -> Double? {
        points.first { Calendar.current.isDate($0.date, inSameDayAs: day) }?.ctl
    }

    /// Tightened Y-range: CTL moves a few points over ±15 days, so a zero-anchored
    /// axis would flatten both curves into indistinguishable lines.
    private var yDomain: ClosedRange<Double> {
        let values = (model.actual + model.planned).map(\.ctl)
        guard let min = values.min(), let max = values.max() else { return 0...1 }
        let pad = Swift.max(2, (max - min) * 0.2)
        return (min - pad)...(max + pad)
    }
}
