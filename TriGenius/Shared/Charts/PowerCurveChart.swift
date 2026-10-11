import SwiftUI
import Charts

// MARK: - Cycling power curve chart
//
// The aggregated max-mean power envelope (`PowerCurve.aggregate`) as a line over
// a logarithmic or linear duration axis, Garmin Connect style, optionally with the
// CP/W′ model's ceiling dashed over its valid window. The readout above the plot
// names the scrubbed point and its ride in place of a tooltip (docs/design.md §4).

struct PowerCurveModel: Codable, Equatable {
    var points: [PowerCurve.Point]
    var cpModel: PowerCurve.Model?
}

struct PowerCurveChart: View {
    enum Scale: CaseIterable {
        case log, linear
        var label: String { self == .log ? "Log" : "Linear" }
    }

    let model: PowerCurveModel
    var scale = Scale.log
    var height: CGFloat = 160

    static let modelColor = Theme.Palette.sport(.bike).opacity(0.55)
    static let modelStroke = StrokeStyle(lineWidth: 2, dash: [4, 3])

    /// The readout's duration while nothing is scrubbed: the 20-minute benchmark.
    private static let restingSeconds = 1200

    @State private var scrub: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.l) {
            readout
            chart
        }
    }

    /// The scrubbed point, else the resting duration — with the model's value at that
    /// duration inside its window.
    private var readout: some View {
        let seconds = scrub.map(Int.init) ?? Self.restingSeconds
        let point = model.points.first { $0.durationSeconds == seconds }
        return VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Circle().fill(Theme.Palette.sport(.bike)).frame(width: 9, height: 9)
                Text(point.map { "\(Int($0.watts.rounded()))" } ?? "—")
                    .font(.largeTitle.bold()).monospacedDigit()
                Text("W").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                if let modelled = model.cpModel?.watts(at: seconds) {
                    Text("CP/W′ model \(Int(modelled.rounded())) W")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                }
            }
            Text([PowerCurve.durationLabel(seconds), point?.activityName,
                  point?.date.formatted(.dateTime.day().month(.abbreviated).year())]
                .compactMap { $0 }.joined(separator: " · "))
                .font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private var chart: some View {
        Chart {
            ForEach(model.points) { point in
                LineMark(
                    x: .value("Duration", Double(point.durationSeconds)),
                    y: .value("Power", point.watts),
                    series: .value("Series", "Best")
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(Theme.Palette.sport(.bike))
            }
            ForEach(modelPoints, id: \.seconds) { p in
                LineMark(
                    x: .value("Duration", Double(p.seconds)),
                    y: .value("Power", p.watts),
                    series: .value("Series", "CP/W′ model")
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(Self.modelColor)
                .lineStyle(Self.modelStroke)
            }
            scrubMarks
        }
        .chartXScale(domain: xDomain, type: scale == .log ? .log : .linear)
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
        .frame(height: height)
        .chartScrubbing($scrub) { nearestPoint(to: $0).map { Double($0.durationSeconds) } }
    }

    @ChartContentBuilder private var scrubMarks: some ChartContent {
        if let scrub {
            RuleMark(x: .value("Scrub", scrub))
                .foregroundStyle(.secondary.opacity(0.6))
                .lineStyle(StrokeStyle(lineWidth: 1))
        }
    }

    /// The model on the grid durations of its window, within the data's span.
    private var modelPoints: [(seconds: Int, watts: Double)] {
        guard let cpModel = model.cpModel else { return [] }
        return PowerCurve.durations.compactMap { d in
            xDomain.contains(Double(d)) ? cpModel.watts(at: d).map { (d, $0) } : nil
        }
    }

    private var maxWatts: Double { (model.points.map(\.watts) + modelPoints.map(\.watts)).max() ?? 1 }

    private var xDomain: ClosedRange<Double> {
        let durations = model.points.map { Double($0.durationSeconds) }
        return (durations.first ?? 1)...(durations.last ?? 2)
    }

    /// Round marks inside the data's span: fixed decades on the log axis, an even
    /// stride of at most five marks on the linear one.
    private var axisDurations: [Double] {
        switch scale {
        case .log:
            return [1.0, 5, 15, 60, 300, 1200, 3600, 14400].filter { xDomain.contains($0) }
        case .linear:
            let step = [60.0, 300, 600, 1800, 3600].first { xDomain.upperBound / $0 <= 5 } ?? 7200
            return Array(stride(from: step, through: xDomain.upperBound, by: step))
        }
    }

    /// Nearest grid point in the axis's own space — equal weight per axis pixel.
    private func nearestPoint(to duration: Double) -> PowerCurve.Point? {
        func axis(_ seconds: Double) -> Double { scale == .log ? log(max(seconds, 1)) : seconds }
        let target = axis(duration)
        return model.points.min {
            abs(axis(Double($0.durationSeconds)) - target) < abs(axis(Double($1.durationSeconds)) - target)
        }
    }
}
