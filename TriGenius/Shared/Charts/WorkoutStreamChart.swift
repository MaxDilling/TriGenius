import SwiftUI
import Charts

// MARK: - Workout metric stream chart
//
// One time-series metric of a completed workout (a decoded
// `WorkoutRecord.streamsData` stream) as a line over elapsed workout time,
// Garmin Connect style. Gap bins (nil — recording pauses) break the line into
// separate segments; pace kinds plot the speed stream as seconds-per-unit on a
// reversed axis (faster = up). Pure value model, no store access.

struct WorkoutStreamModel: Codable, Equatable, Identifiable {
    enum Kind: String, Codable {
        case speed, power, heartRate, runPace, swimPace, bikeCadence, runCadence, elevation
    }
    var kind: Kind
    var binSeconds: Int
    /// Natural units per bin (m/s, W, bpm, rpm/spm, m); nil = recording gap.
    var values: [Double?]
    var id: String { kind.rawValue }

    /// Chart models for a workout's stored streams, in the sport's display order;
    /// pace sports render the speed stream as pace.
    static func models(from data: Data, family: SportFamily) -> [WorkoutStreamModel] {
        guard let decoded = WorkoutStreams.decode(data) else { return [] }
        let order: [(WorkoutStreams.Metric, Kind)] = switch family {
        case .bike:
            [(.speed, .speed), (.power, .power), (.heartRate, .heartRate),
             (.cadence, .bikeCadence), (.elevation, .elevation)]
        case .run:
            [(.speed, .runPace), (.heartRate, .heartRate), (.power, .power),
             (.cadence, .runCadence), (.elevation, .elevation)]
        case .swim:
            [(.speed, .swimPace), (.heartRate, .heartRate)]
        case .strength, .other:
            [(.heartRate, .heartRate)]
        }
        return order.compactMap { metric, kind in
            decoded.metrics[metric].map {
                WorkoutStreamModel(kind: kind, binSeconds: decoded.binSeconds, values: $0)
            }
        }
    }
}

extension WorkoutStreamModel.Kind {
    var label: String {
        switch self {
        case .speed: "Speed"
        case .power: "Power"
        case .heartRate: "Heart rate"
        case .runPace, .swimPace: "Pace"
        case .bikeCadence, .runCadence: "Cadence"
        case .elevation: "Elevation"
        }
    }

    var color: Color {
        switch self {
        case .speed: Theme.Palette.info
        case .power: Theme.Palette.sport(.bike)
        case .heartRate: Theme.Palette.danger
        case .runPace: Theme.Palette.sport(.run)
        case .swimPace: Theme.Palette.sport(.swim)
        case .bikeCadence, .runCadence: Theme.Palette.success
        case .elevation: .gray
        }
    }

    /// The plotted value for a natural-unit sample: pace kinds become
    /// seconds-per-unit, speed plots in km/h (matching its axis/tooltip).
    /// A near-stop bin (GPS jitter while paused) is nil for pace — a pace is
    /// over moving time, and its inverse blows up toward a stop.
    func display(_ value: Double) -> Double? {
        switch self {
        case .runPace: value >= 0.5 ? 1000 / value : nil    // slower than 33 min/km = not moving
        case .swimPace: value >= 0.2 ? 100 / value : nil    // slower than 8:20 /100m = not moving
        case .speed: value * 3.6
        default: value
        }
    }

    /// Y-axis tick label for a plotted value.
    func axisLabel(_ display: Double) -> String {
        switch self {
        case .runPace, .swimPace: Self.pace(display)
        default: "\(Int(display.rounded()))"
        }
    }

    /// Tooltip formatting from the natural-unit value.
    func format(_ value: Double) -> String {
        switch self {
        case .speed: String(format: "%.1f km/h", value * 3.6)
        case .power: "\(Int(value.rounded())) W"
        case .heartRate: "\(Int(value.rounded())) bpm"
        case .runPace: Self.pace(1000 / value) + " /km"
        case .swimPace: Self.pace(100 / value) + " /100m"
        case .bikeCadence: "\(Int(value.rounded())) rpm"
        case .runCadence: "\(Int(value.rounded())) spm"
        case .elevation: "\(Int(value.rounded())) m"
        }
    }

    private static func pace(_ secondsPer: Double) -> String {
        let s = Int(secondsPer.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

struct WorkoutStreamChart: View {
    let model: WorkoutStreamModel

    @State private var scrubOffset: Double?
    private let segments: [Segment]

    init(model: WorkoutStreamModel) {
        self.model = model
        self.segments = Self.segments(of: model)
    }

    var body: some View {
        Chart {
            ForEach(segments) { segment in
                ForEach(segment.points) { point in
                    LineMark(
                        x: .value("Time", point.offset),
                        y: .value(model.kind.label, point.display),
                        series: .value("Segment", segment.id)
                    )
                    .foregroundStyle(model.kind.color)
                }
            }
            scrubMarks
        }
        .chartYScale(domain: yDomain)
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel {
                    if let v = value.as(Double.self) { Text(model.kind.axisLabel(v)) }
                }
            }
        }
        .chartXScale(domain: 0...(Double(model.values.count * model.binSeconds)))
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let seconds = value.as(Double.self) { Text(Self.timeLabel(seconds)) }
                }
            }
        }
        .chartPlotStyle { $0.clipped() }   // an off-domain pace spike clips, not overflows
        .frame(height: 140)
        .chartScrubbing($scrubOffset) { nearestPoint(to: $0)?.offset }
    }

    @ChartContentBuilder private var scrubMarks: some ChartContent {
        if let offset = scrubOffset, let point = nearestPoint(to: offset) {
            RuleMark(x: .value("Scrub", point.offset))
                .foregroundStyle(.secondary.opacity(0.6))
                .lineStyle(StrokeStyle(lineWidth: 1))
                .annotation(position: .top, spacing: 0,
                            overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .plot))) {
                    ChartTooltip(
                        title: Self.timeLabel(point.offset),
                        rows: [.init(color: model.kind.color, label: model.kind.label,
                                     value: model.kind.format(point.value))]
                    )
                }
        }
    }

    private struct Point: Identifiable {
        let offset: Double    // bin center, elapsed seconds
        let value: Double     // natural units
        let display: Double   // plotted (pace transform applied)
        var id: Double { offset }
    }

    private struct Segment: Identifiable {
        let id: Int
        let points: [Point]
    }

    /// Contiguous non-gap runs — one line series each, so pauses break the line.
    private static func segments(of model: WorkoutStreamModel) -> [Segment] {
        let bin = Double(model.binSeconds)
        var segments: [Segment] = []
        var current: [Point] = []
        for (i, value) in model.values.enumerated() {
            if let value, let display = model.kind.display(value) {
                current.append(Point(offset: (Double(i) + 0.5) * bin, value: value, display: display))
            } else if !current.isEmpty {
                segments.append(Segment(id: segments.count, points: current))
                current = []
            }
        }
        if !current.isEmpty { segments.append(Segment(id: segments.count, points: current)) }
        return segments
    }

    /// Rate/effort kinds anchor at zero; level kinds (HR, elevation) tighten to
    /// the data; pace reverses (faster = up) and scales to the 98th percentile so
    /// a lone walk/stop spike clips instead of squashing the run.
    private var yDomain: [Double] {
        let displays = segments.flatMap { $0.points.map(\.display) }.sorted()
        guard let lo = displays.first, let hi = displays.last, hi > 0 else { return [0, 1] }
        switch model.kind {
        case .speed, .power, .bikeCadence, .runCadence:
            return [0, hi * 1.1]
        case .runPace, .swimPace:
            let p98 = displays[Int(0.98 * Double(displays.count - 1))]
            let pad = max((p98 - lo) * 0.15, p98 * 0.02)
            return [p98 + pad, max(lo - pad, 0)]
        case .heartRate, .elevation:
            let pad = max((hi - lo) * 0.15, hi * 0.02)
            return [max(lo - pad, 0), hi + pad]
        }
    }

    private func nearestPoint(to offset: Double) -> Point? {
        segments.lazy.flatMap(\.points).min { abs($0.offset - offset) < abs($1.offset - offset) }
    }

    /// Elapsed-time axis/tooltip label: `m:ss` under an hour, `h:mm` above.
    private static func timeLabel(_ seconds: Double) -> String {
        let s = Int(seconds)
        return s >= 3600 ? String(format: "%d:%02d", s / 3600, (s % 3600) / 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }
}
