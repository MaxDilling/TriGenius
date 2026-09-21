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
    /// A *measured* level drawn as a rule across the plot — normalized power on
    /// a bike power trace. Never an average standing in for one that is missing.
    struct Reference: Codable, Equatable {
        let value: Double   // natural units
        let label: String
    }

    var kind: Kind
    var binSeconds: Int
    /// Natural units per bin (m/s, W, bpm, rpm/spm, m); nil = recording gap.
    var values: [Double?]
    var reference: Reference? = nil
    /// The z1–z4 upper bounds this workout was bucketed against, in the metric's
    /// own unit — the shading behind the trace. Nil where the discipline has no
    /// zone model or the threshold behind it was unknown.
    var zones: [Double]? = nil
    /// Seconds in z1…z5 as bucketed at ingest — the exact figures, not a count
    /// of the buckets currently on screen.
    var zoneSeconds: [Double]? = nil
    var id: String { kind.rawValue }
    /// Elapsed seconds the stored bins cover.
    var spanSeconds: Double { Double(values.count * binSeconds) }
    /// What `StreamPlot` needs to lay this metric out.
    var plotMetric: StreamPlot.Metric {
        .init(axis: kind.axis, framing: kind.framing, zones: zones, bridgesGaps: kind == .elevation)
    }

    /// Chart models for a workout's stored streams, in the sport's display order;
    /// pace sports render the speed stream as pace. `details` supplies the
    /// reference levels the source measured at full stream resolution.
    static func models(from data: Data, details: [String: Any],
                       family: SportFamily) -> [WorkoutStreamModel] {
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
                WorkoutStreamModel(kind: kind, binSeconds: decoded.binSeconds, values: $0,
                                   reference: reference(kind, details),
                                   zones: kind.zoneMetric.flatMap {
                                       ZoneDistribution.zoneBounds(details: details, metric: $0)
                                   },
                                   zoneSeconds: kind.zoneMetric.flatMap {
                                       ZoneDistribution.zoneSeconds(details: details, metric: $0)
                                   })
            }
        }
    }

    /// The stored normalized power — computed at ingest over the full-resolution
    /// stream, so it is read here, never recomputed from the downsampled bins.
    private static func reference(_ kind: Kind, _ details: [String: Any]) -> Reference? {
        guard kind == .power,
              let np = Coerce.double((details["cycling"] as? [String: Any])?["normalized_power_w"]),
              np > 0
        else { return nil }
        return Reference(value: np, label: "NP")
    }

    /// Race-wide models for a multisport session: every leg's stored bins placed
    /// on one elapsed-race timeline (a leg's gap between end and the next start
    /// stays nil, so the line breaks there). Only heart rate and elevation
    /// combine — cadence, power and pace mean different things per discipline,
    /// so one series across the legs would be a number that never existed.
    static func raceModels(segments: [WorkoutSegment]) -> [WorkoutStreamModel] {
        let legs = segments.compactMap { segment -> (offset: Double, decoded: WorkoutStreams.Decoded)? in
            WorkoutStreams.decode(segment.streamsData).map { (segment.offsetSeconds, $0) }
        }
        let span: Double = legs.map { leg in
            let bins: Int = leg.decoded.metrics.values.first?.count ?? 0
            return leg.offset + Double(bins * leg.decoded.binSeconds)
        }.max() ?? 0
        guard span > 0 else { return [] }
        let bin = WorkoutStreams.binSeconds(spanSeconds: span)
        let count = Int((span / Double(bin)).rounded(.up))

        return [(WorkoutStreams.Metric.heartRate, Kind.heartRate), (.elevation, .elevation)]
            .compactMap { metric, kind in
                var sums = [Double](repeating: 0, count: count)
                var hits = [Int](repeating: 0, count: count)
                for leg in legs {
                    guard let values = leg.decoded.metrics[metric] else { continue }
                    for (i, value) in values.enumerated() {
                        guard let value else { continue }
                        let center = leg.offset + (Double(i) + 0.5) * Double(leg.decoded.binSeconds)
                        let slot = Int(center) / bin
                        guard slot >= 0, slot < count else { continue }
                        sums[slot] += value
                        hits[slot] += 1
                    }
                }
                guard hits.contains(where: { $0 > 0 }) else { return nil }
                return WorkoutStreamModel(
                    kind: kind, binSeconds: bin,
                    values: (0..<count).map { hits[$0] == 0 ? nil : sums[$0] / Double(hits[$0]) })
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

    /// The zone model this trace shades against — nil where the metric has none
    /// (bike speed, cadence, elevation, and swim, which has no pace zones).
    var zoneMetric: ZoneMetric? {
        switch self {
        case .power: .power
        case .heartRate: .heartRate
        case .runPace: .pace
        default: nil
        }
    }

    /// How the natural-unit samples reach the plot: pace kinds invert to
    /// seconds-per-unit, speed plots in km/h (matching its axis and tooltip).
    /// The pace floors are where the athlete counts as standing still — slower
    /// than 33 min/km running, 8:20 /100m swimming.
    var axis: StreamPlot.Axis {
        switch self {
        case .runPace: .inverse(scale: 1000, floor: 0.5)
        case .swimPace: .inverse(scale: 100, floor: 0.2)
        case .speed: .linear(3.6)
        default: .linear(1)
        }
    }

    /// Rates and efforts are read against zero; levels the athlete is always at
    /// (heart rate, altitude) would waste the plot on the empty space below.
    var framing: StreamPlot.Framing {
        switch self {
        case .heartRate, .elevation: .tight
        default: .fromZero
        }
    }

    /// Y-axis tick label for a plotted value.
    func axisLabel(_ display: Double) -> String {
        switch self {
        case .runPace, .swimPace: Self.pace(display)
        default: "\(Int(display.rounded()))"
        }
    }

    var unit: String {
        switch self {
        case .speed: "km/h"
        case .power: "W"
        case .heartRate: "bpm"
        case .runPace: "/km"
        case .swimPace: "/100m"
        case .bikeCadence: "rpm"
        case .runCadence: "spm"
        case .elevation: "m"
        }
    }

    /// Tooltip formatting from the natural-unit value — the number the axis
    /// shows plus its unit, with a decimal for speed, where whole km/h is coarse.
    func format(_ value: Double) -> String {
        let plotted = axis.display(value)
        let number = self == .speed ? String(format: "%.1f", plotted) : axisLabel(plotted)
        return number + " " + unit
    }

    /// "42–310 W" — two natural-unit values ordered by plot position (a pace
    /// axis inverts them), with the unit stated once at the end.
    func rangeText(_ a: Double, _ b: Double) -> String {
        let (lo, hi) = axis.display(a) <= axis.display(b) ? (a, b) : (b, a)
        return axisLabel(axis.display(lo)) + "–" + format(hi)
    }

    private static func pace(_ secondsPer: Double) -> String {
        let s = Int(secondsPer.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

struct WorkoutStreamChart: View {

    /// A shaded elapsed-time span behind the trace — the legs of a multisport
    /// session on a race-wide chart.
    struct Band: Identifiable {
        let start: Double
        let end: Double
        let color: Color
        var id: Double { start }
    }

    /// The visible window onto the workout, and the only place its arithmetic
    /// lives — the chart's own drag/pinch and the detail sheet's buttons both go
    /// through it. Nil shows the whole workout and takes no gestures.
    struct Zoom: Equatable {
        private(set) var span: Double    // visible seconds
        private(set) var start: Double   // leading edge, elapsed seconds
        let full: Double
        /// Never zoom past the stored resolution — a couple of dozen bins on screen.
        let minSpan: Double

        init(full: Double, binSeconds: Int) {
            self.span = full
            self.start = 0
            self.full = full
            self.minSpan = min(full, Double(binSeconds * 20))
        }

        var window: ClosedRange<Double> { start...(start + span) }
        var isFit: Bool { span >= full }
        var canZoomIn: Bool { span > minSpan }

        /// Re-centre on the midpoint, so a zoom keeps what you were looking at.
        mutating func zoom(to span: Double) {
            let centre = start + self.span / 2
            self.span = min(max(span, minSpan), full)
            start = clamp(centre - self.span / 2)
        }

        /// `origin` is the window the drag started from, so the pan tracks the
        /// gesture rather than accumulating rounding on every event.
        mutating func pan(from origin: Double, bySeconds delta: Double) {
            start = clamp(origin + delta)
        }

        private func clamp(_ start: Double) -> Double { min(max(start, 0), full - span) }
    }

    let model: WorkoutStreamModel
    /// A second metric of the same workout, drawn as a silhouette behind the
    /// trace for context (heart rate against the climb it was earned on).
    let overlay: WorkoutStreamModel?
    let bands: [Band]
    /// Plot height; nil lets the chart fill what it is given.
    let height: CGFloat?
    let zoom: Binding<Zoom>?
    /// The zone the pointer is resting on in the ribbon, reported up so a host
    /// can spell it out. Nil whenever the trace itself is being scrubbed.
    let highlight: Binding<Int?>?

    @State private var scrubOffset: Double?
    /// The plot rectangle itself: its width sets the smoothing bucket, its
    /// height keeps the zone ribbon a constant thickness instead of a share of
    /// however tall the chart happens to be.
    @State private var plotSize: CGSize = .zero
    /// Where the running drag/pinch began — a gesture reports against its own
    /// start, not against the window it last produced.
    @State private var panStart: Double?
    @State private var pinchStart: Double?
    /// Whether the pointer is down on the zone ribbon rather than the trace.
    @State private var onRibbon = false
    private let yDomain: StreamPlot.Domain

    /// The zone ribbon's thickness in points — constant, so a tall plot does not
    /// hand it more of the chart than it needs — and the taller strip that counts
    /// as touching it, since 6 pt is a poor finger target.
    private static let ribbonPoints = 6.0
    private static let ribbonTouchPoints = 26.0

    init(model: WorkoutStreamModel, overlay: WorkoutStreamModel? = nil, bands: [Band] = [],
         height: CGFloat? = 140, zoom: Binding<Zoom>? = nil,
         highlight: Binding<Int?>? = nil) {
        self.model = model
        self.overlay = overlay
        self.bands = bands
        self.height = height
        self.zoom = zoom
        self.highlight = highlight
        self.yDomain = StreamPlot.domain(values: model.values, metric: model.plotMetric)
    }

    var body: some View {
        Group {
            if zoom != nil {
                chart.gesture(panAndZoom)
            } else {
                chart
            }
        }
        // After the update, never during it: the zone is derived from the same
        // bucketing the marks are drawn from.
        .onChange(of: highlightedZone) { _, zone in highlight?.wrappedValue = zone }
    }

    /// The bucketing this pass renders, and the zone stretches over it.
    private var plot: (segments: [StreamPlot.Segment], runs: [StreamPlot.Run]) {
        let segments = StreamPlot.segments(
            values: model.values, binSeconds: model.binSeconds, metric: model.plotMetric,
            visibleSpan: zoom?.wrappedValue.span ?? model.spanSeconds,
            plotWidth: plotSize.width > 0 ? plotSize.width : 320)
        return (segments, StreamPlot.zoneRuns(of: segments))
    }

    /// The zone under the pointer, but only while it rests on the ribbon —
    /// scrubbing the trace itself reads values, not zones.
    private var highlightedZone: Int? {
        guard onRibbon, let offset = scrubOffset else { return nil }
        return plot.runs.first { offset >= $0.start && offset <= $0.end }?.zone
    }

    /// Drag to pan, pinch to zoom. A scrollable chart would be the framework's
    /// own answer, but it only pans on a *horizontal* scroll event — which a
    /// plain mouse never sends. Converting the drag through the measured plot
    /// width instead means the trace follows the cursor one-to-one everywhere.
    private var panAndZoom: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                guard let zoom else { return }
                #if os(iOS)
                // A long press that is already scrubbing owns the finger. macOS
                // scrubs on hover, which is never a drag, so it never competes.
                guard scrubOffset == nil || panStart != nil else { return }
                #endif
                let from = panStart ?? zoom.wrappedValue.start
                panStart = from
                let seconds = -value.translation.width / max(plotSize.width, 1) * zoom.wrappedValue.span
                zoom.wrappedValue.pan(from: from, bySeconds: seconds)
            }
            .onEnded { _ in panStart = nil }
            .simultaneously(with: MagnifyGesture()
                .onChanged { value in
                    guard let zoom else { return }
                    let base = pinchStart ?? zoom.wrappedValue.span
                    pinchStart = base
                    zoom.wrappedValue.zoom(to: base / value.magnification)
                }
                .onEnded { _ in pinchStart = nil })
    }

    private var chart: some View {
        // Before the first geometry pass a phone-ish width stands in, so the
        // first frame draws a sane trace instead of an empty plot.
        let visible = zoom?.wrappedValue.span ?? model.spanSeconds
        let width = plotSize.width > 0 ? plotSize.width : 320
        let (segments, runs) = plot
        let overlaid = overlay.map { Overlaid($0, visibleSpan: visible, plotWidth: width,
                                              into: yDomain) }
        return Chart {
            if let overlaid {
                ForEach(overlaid.segments) { segment in
                    ForEach(segment.vertices) { vertex in
                        AreaMark(x: .value("Time", vertex.offset),
                                 yStart: .value(overlaid.model.kind.label, overlaid.base),
                                 yEnd: .value(overlaid.model.kind.label, overlaid.scale(vertex.plot)),
                                 series: .value("Overlay", "o\(segment.id)"))
                            .foregroundStyle(overlaid.model.kind.color.opacity(0.20))
                    }
                }
            }
            ForEach(bands) { band in
                RectangleMark(xStart: .value("Start", band.start), xEnd: .value("End", band.end))
                    .foregroundStyle(band.color.opacity(0.14))
            }
            ForEach(segments) { segment in
                ForEach(segment.vertices) { vertex in
                    if vertex.plotLow < vertex.plotHigh {
                        AreaMark(
                            x: .value("Time", vertex.offset),
                            yStart: .value(model.kind.label, vertex.plotLow),
                            yEnd: .value(model.kind.label, vertex.plotHigh),
                            series: .value("Spread", "s\(segment.id)")
                        )
                        .foregroundStyle(model.kind.color.opacity(0.18))
                    }
                    LineMark(
                        x: .value("Time", vertex.offset),
                        y: .value(model.kind.label, vertex.plot),
                        series: .value("Trace", "t\(segment.id)")
                    )
                    .foregroundStyle(model.kind.color)
                    // Pinned, not left to the default: the same stroke has to
                    // read the same on a tiled card and in the full-size sheet,
                    // and a dense trace at 2 pt closes into a solid block.
                    .lineStyle(StrokeStyle(lineWidth: 1.4, lineJoin: .round))
                }
            }
            zoneMarks(runs)
            referenceMark
            scrubMarks(in: segments, overlaid: overlaid)
        }
        .chartYScale(domain: yDomain.bounds)
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel {
                    if let v = value.as(Double.self) { Text(model.kind.axisLabel(v)) }
                }
            }
        }
        .chartXScale(domain: zoom?.wrappedValue.window ?? 0...model.spanSeconds)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let seconds = value.as(Double.self) { Text(Self.timeLabel(seconds)) }
                }
            }
        }
        .chartPlotStyle { plot in
            plot
                .clipped()   // an off-domain pace spike clips, not overflows
                .onGeometryChange(for: CGSize.self) { $0.size } action: { plotSize = $0 }
        }
        .frame(height: height)
        .chartScrubbing($scrubOffset, footer: Self.ribbonFraction(Self.ribbonTouchPoints,
                                                                  in: plotSize.height),
                        inFooter: $onRibbon) {
            StreamPlot.nearest(to: $0, in: segments)?.offset
        }
    }

    /// The zone timeline as a ribbon along the bottom of the plot, and — while
    /// the pointer rests on one of its colours — every *other* stretch of that
    /// same zone shaded full height, so a glance answers "where else did I ride
    /// this hard?".
    @ChartContentBuilder private func zoneMarks(_ runs: [StreamPlot.Run]) -> some ChartContent {
        let highlight = highlightedZone
        ForEach(runs) { run in
            if let zone = run.zone {
                if zone == highlight {
                    RectangleMark(xStart: .value("From", run.start), xEnd: .value("To", run.end))
                        .foregroundStyle(Theme.Palette.zones[zone].opacity(0.18))
                }
                RectangleMark(xStart: .value("From", run.start), xEnd: .value("To", run.end),
                              yStart: .value(model.kind.label, yDomain.floor),
                              yEnd: .value(model.kind.label, yDomain.fromFloor(
                                  Self.ribbonFraction(Self.ribbonPoints, in: plotSize.height))))
                    .foregroundStyle(Theme.Palette.zones[zone]
                        .opacity(highlight == nil || zone == highlight ? 1 : 0.35))
            }
        }
    }

    /// A thickness in points as a share of the plot, capped so a chart too short
    /// to have measured itself yet cannot give the ribbon the whole plot.
    private static func ribbonFraction(_ points: Double, in height: CGFloat) -> Double {
        min(points / max(height, 1), 0.2)
    }

    /// The measured reference level as a dashed rule across the plot.
    @ChartContentBuilder private var referenceMark: some ChartContent {
        if let reference = model.reference {
            RuleMark(y: .value(model.kind.label, model.kind.axis.display(reference.value)))
                .foregroundStyle(model.kind.color.opacity(0.7))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .annotation(position: .top, alignment: .trailing, spacing: 1,
                            overflowResolution: .init(x: .fit(to: .plot), y: .fit(to: .plot))) {
                    Text("\(reference.label) \(model.kind.format(reference.value))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
        }
    }

    @ChartContentBuilder
    private func scrubMarks(in segments: [StreamPlot.Segment],
                            overlaid: Overlaid?) -> some ChartContent {
        if let offset = scrubOffset, highlightedZone == nil,
           let vertex = StreamPlot.nearest(to: offset, in: segments) {
            RuleMark(x: .value("Scrub", vertex.offset))
                .foregroundStyle(.secondary.opacity(0.6))
                .lineStyle(StrokeStyle(lineWidth: 1))
                .annotation(position: .top, spacing: 0,
                            overflowResolution: .init(x: .fit(to: .plot), y: .fit(to: .plot))) {
                    ChartTooltip(title: Self.timeLabel(vertex.offset),
                                 rows: tooltipRows(vertex, overlaid: overlaid))
                }
        }
    }

    /// The bucket's mean, the raw spread it averaged away, and the overlay's
    /// own value at the same moment — the overlay shares the plot but not the
    /// axis, so the tooltip is where its real numbers are read.
    private func tooltipRows(_ vertex: StreamPlot.Vertex, overlaid: Overlaid?) -> [ChartTooltip.Row] {
        var rows = [ChartTooltip.Row(color: model.kind.color, label: model.kind.label,
                                     value: model.kind.format(vertex.mean))]
        if vertex.plotLow < vertex.plotHigh {
            rows.append(.init(color: nil, label: "Range",
                              value: model.kind.rangeText(vertex.low, vertex.high)))
        }
        if let overlaid, let at = StreamPlot.nearest(to: vertex.offset, in: overlaid.segments) {
            rows.append(.init(color: overlaid.model.kind.color, label: overlaid.model.kind.label,
                              value: overlaid.model.kind.format(at.mean)))
        }
        return rows
    }

    /// The overlay, bucketed on the same grid as the trace and mapped from its
    /// own domain onto the primary's. Deliberately no second Y axis: two metrics
    /// on one plot are not comparable, and an axis would imply they are.
    private struct Overlaid {
        let model: WorkoutStreamModel
        let segments: [StreamPlot.Segment]
        let scale: StreamPlot.Rescale
        /// The floor the silhouette fills from.
        var base: Double { scale.target.lo }

        init(_ model: WorkoutStreamModel, visibleSpan: Double, plotWidth: Double,
             into target: StreamPlot.Domain) {
            self.model = model
            self.segments = StreamPlot.segments(values: model.values, binSeconds: model.binSeconds,
                                                metric: model.plotMetric,
                                                visibleSpan: visibleSpan, plotWidth: plotWidth)
            self.scale = StreamPlot.Rescale(
                source: StreamPlot.domain(values: model.values, metric: model.plotMetric),
                target: target)
        }
    }

    /// Elapsed-time axis/tooltip label: `m:ss` under an hour, `h:mm` above.
    private static func timeLabel(_ seconds: Double) -> String {
        let s = Int(seconds)
        return s >= 3600 ? String(format: "%d:%02d", s / 3600, (s % 3600) / 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }
}
