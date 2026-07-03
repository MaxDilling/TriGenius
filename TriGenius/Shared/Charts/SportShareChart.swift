import SwiftUI
import Charts

// MARK: - Sport share chart
//
// TrainingPeaks-style distribution-by-discipline: stacked weekly bars plus a
// per-sport share-of-total legend. The Codable model carries semantic sports,
// never colors — tints resolve from `Theme.Palette.sport` at render time.

struct SportShareModel: Codable, Equatable {

    enum Metric: String, Codable, CaseIterable {
        case tss, duration, distance

        var label: String {
            switch self {
            case .tss: return "TSS"
            case .duration: return "h"
            case .distance: return "km"
            }
        }
    }

    struct Week: Codable, Equatable, Identifiable {
        struct Slice: Codable, Equatable {
            var sport: SportFamily
            var value: Double
        }
        var weekStart: Date
        var slices: [Slice]
        var id: Date { weekStart }
    }

    var metric: Metric
    var weeks: [Week]

    /// Range total per sport, descending — feeds the legend.
    var totals: [(sport: SportFamily, value: Double)] {
        var acc: [SportFamily: Double] = [:]
        for week in weeks {
            for slice in week.slices { acc[slice.sport, default: 0] += slice.value }
        }
        return acc.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
    }
}

struct SportShareChart: View {
    let model: SportShareModel

    @State private var scrubDate: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Chart {
                ForEach(model.weeks) { week in
                    ForEach(week.slices, id: \.sport) { slice in
                        BarMark(
                            x: .value("Week", week.weekStart, unit: .weekOfYear),
                            y: .value(model.metric.label, slice.value)
                        )
                        .foregroundStyle(Theme.Palette.sport(slice.sport))
                    }
                }
                scrubMarks
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .month)) {
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.month(.abbreviated), collisionResolution: .greedy)
                }
            }
            .frame(height: 180)
            .chartDateScrubbing($scrubDate)
            legend
        }
    }

    @ChartContentBuilder private var scrubMarks: some ChartContent {
        if let date = scrubDate,
           let week = model.weeks.last(where: { $0.weekStart <= date }),
           !week.slices.isEmpty {
            RuleMark(x: .value("Scrub", week.weekStart, unit: .weekOfYear))
                .foregroundStyle(.secondary.opacity(0.6))
                .lineStyle(StrokeStyle(lineWidth: 1))
                .annotation(position: .top, spacing: 0,
                            overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                    ChartTooltip(
                        title: "Week of \(week.weekStart.formatted(.dateTime.day().month(.abbreviated)))",
                        rows: week.slices
                            .sorted { $0.value > $1.value }
                            .map { slice in
                                .init(color: Theme.Palette.sport(slice.sport),
                                      label: slice.sport.displayName,
                                      value: "\(slice.value.formatted(.number.precision(.fractionLength(0...1)))) \(model.metric.label)")
                            }
                    )
                }
        }
    }

    private var legend: some View {
        let totals = model.totals
        let total = max(1, totals.reduce(0) { $0 + $1.value })
        return HStack(spacing: Theme.Spacing.m) {
            ForEach(totals, id: \.sport) { entry in
                HStack(spacing: 3) {
                    Circle().fill(Theme.Palette.sport(entry.sport)).frame(width: 7, height: 7)
                    Text(entry.sport.displayName).font(.caption2).foregroundStyle(.secondary)
                    Text("\(Int((entry.value / total * 100).rounded()))%")
                        .font(.caption2).monospacedDigit()
                }
            }
        }
    }
}
