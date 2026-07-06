import SwiftUI
import Charts

// MARK: - Cycling power curve chart
//
// The aggregated max-mean power envelope (`PowerCurve.aggregate`) as a line over
// a logarithmic duration axis, Garmin Connect style. The tooltip attributes the
// scrubbed point to the ride that set it.

struct PowerCurveModel: Codable, Equatable {
    var points: [PowerCurve.Point]
}

struct PowerCurveChart: View {
    let model: PowerCurveModel

    @State private var scrubDuration: Double?

    var body: some View {
        Chart {
            ForEach(model.points) { point in
                LineMark(
                    x: .value("Duration", Double(point.durationSeconds)),
                    y: .value("Power", point.watts)
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(Theme.Palette.sport(.bike))
            }
            scrubMarks
        }
        .chartXScale(domain: xDomain, type: .log)
        .chartYScale(domain: 0...(maxWatts * 1.1))
        .chartXAxis {
            AxisMarks(values: axisDurations) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let seconds = value.as(Double.self) {
                        Text(PowerCurve.durationLabel(Int(seconds)))
                    }
                }
            }
        }
        .frame(height: 160)
        .chartScrubbing($scrubDuration) { nearestPoint(to: $0).map { Double($0.durationSeconds) } }
    }

    @ChartContentBuilder private var scrubMarks: some ChartContent {
        if let duration = scrubDuration, let point = nearestPoint(to: duration) {
            RuleMark(x: .value("Scrub", Double(point.durationSeconds)))
                .foregroundStyle(.secondary.opacity(0.6))
                .lineStyle(StrokeStyle(lineWidth: 1))
                .annotation(position: .top, spacing: 0,
                            overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                    ChartTooltip(
                        title: PowerCurve.durationLabel(point.durationSeconds),
                        rows: [
                            .init(color: Theme.Palette.sport(.bike), label: "Power",
                                  value: "\(Int(point.watts.rounded())) W"),
                            .init(color: nil, label: point.activityName,
                                  value: point.date.formatted(date: .abbreviated, time: .omitted)),
                        ]
                    )
                }
        }
    }

    private var maxWatts: Double { model.points.map(\.watts).max() ?? 1 }

    private var xDomain: ClosedRange<Double> {
        let durations = model.points.map { Double($0.durationSeconds) }
        return (durations.first ?? 1)...(durations.last ?? 2)
    }

    /// Round marks inside the data's span (the log axis has no natural stride).
    private var axisDurations: [Double] {
        [1.0, 5, 15, 60, 300, 1200, 3600, 14400].filter { xDomain.contains($0) }
    }

    /// Nearest grid point in log space — equal weight per axis pixel, not per second.
    private func nearestPoint(to duration: Double) -> PowerCurve.Point? {
        let target = log(max(duration, 1))
        return model.points.min {
            abs(log(Double($0.durationSeconds)) - target) < abs(log(Double($1.durationSeconds)) - target)
        }
    }
}
