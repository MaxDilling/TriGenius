import SwiftUI
import Charts

// MARK: - Ramp rate chart
//
// Weekly CTL change as bars over the TrainingPeaks safe build band (shaded), the
// ATP's planned change as grey bars behind them — as on the ATP chart. Positive
// deltas inside the band are a sustainable build; above it, a ramp warning;
// negative, recovery/detraining.

struct RampRateModel: Codable, Equatable {
    var weeks: [RampWeek]
    /// The plan curve's change over the same weeks; weeks before the plan starts drop out.
    var planned: [RampWeek]
}

struct RampRateChart: View {
    let model: RampRateModel

    @State private var scrubDate: Date?

    var body: some View {
        Chart {
            RectangleMark(
                yStart: .value("Band", RampRate.safeBand.lowerBound),
                yEnd: .value("Band", RampRate.safeBand.upperBound)
            )
            .foregroundStyle(Theme.Palette.success.opacity(0.12))
            ForEach(model.planned) { week in
                BarMark(x: .value("Week", week.weekStart, unit: .weekOfYear),
                        y: .value("Planned ΔCTL", week.delta), stacking: .unstacked)
                    .foregroundStyle(Theme.Palette.plan.opacity(0.45))
            }
            ForEach(model.weeks) { week in
                BarMark(x: .value("Week", week.weekStart, unit: .weekOfYear),
                        y: .value("ΔCTL", week.delta), stacking: .unstacked)
                    .foregroundStyle(Theme.Palette.info)
            }
            RuleMark(y: .value("Zero", 0))
                .foregroundStyle(.secondary.opacity(0.4))
                .lineStyle(StrokeStyle(lineWidth: 1))
            scrubMarks
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .month)) {
                AxisGridLine()
                AxisValueLabel(format: .dateTime.month(.abbreviated), collisionResolution: .greedy)
            }
        }
        .frame(height: 160)
        .chartScrubbing($scrubDate) { week(containing: $0)?.weekStart }
    }

    @ChartContentBuilder private var scrubMarks: some ChartContent {
        if let date = scrubDate, let week = week(containing: date) {
            RuleMark(x: .value("Scrub", week.weekStart, unit: .weekOfYear))
                .foregroundStyle(.secondary.opacity(0.6))
                .lineStyle(StrokeStyle(lineWidth: 1))
                .annotation(position: .top, spacing: 0,
                            overflowResolution: .init(x: .fit(to: .plot), y: .fit(to: .plot))) {
                    ChartTooltip(
                        title: "Week of \(week.weekStart.formatted(.dateTime.day().month(.abbreviated)))",
                        rows: [
                            .init(color: Theme.Palette.info, label: "ΔCTL",
                                  value: week.delta.formatted(.number.precision(.fractionLength(1)).sign(strategy: .always()))),
                        ] + model.planned.filter { $0.weekStart == week.weekStart }.map {
                            .init(color: Theme.Palette.plan, label: "Plan",
                                  value: $0.delta.formatted(.number.precision(.fractionLength(1)).sign(strategy: .always())))
                        } + [
                            .init(color: nil, label: "CTL",
                                  value: week.ctlEnd.formatted(.number.precision(.fractionLength(1)))),
                        ]
                    )
                }
        }
    }

    private func week(containing date: Date) -> RampWeek? {
        model.weeks.last { $0.weekStart <= date }
    }
}
