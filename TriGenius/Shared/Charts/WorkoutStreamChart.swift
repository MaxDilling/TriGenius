import SwiftUI
import Charts

// MARK: - Workout metric stream chart
//
// One time-series metric of a completed workout (a decoded
// `WorkoutRecord.streamsData` stream) as a line over elapsed workout time,
// Garmin Connect style. Gap bins (nil — recording pauses) break the line into
// separate segments; pace kinds plot the speed stream as seconds-per-unit on a
// reversed axis (faster = up). Pure value model, no store access.

struct WorkoutStreamModel: Equatable, Identifiable {
    enum Kind: String {
        case speed, power, heartRate, runPace, hikePace, swimPace, bikeCadence, runCadence, elevation
    }
    /// A *measured* level drawn as a rule across the plot — normalized power on
    /// a bike power trace. Never an average standing in for one that is missing.
    struct Reference: Equatable {
        let value: Double   // natural units
        let label: String
    }

    let kind: Kind
    let binSeconds: Int
    /// Natural units per bin (m/s, W, bpm, rpm/spm, m); nil = recording gap.
    let values: [Double?]
    let reference: Reference?
    /// The z1–z4 upper bounds this workout was bucketed against, in the metric's
    /// own unit — the shading behind the trace. Nil where the discipline has no
    /// zone model or the threshold behind it was unknown.
    let zones: [Double]?
    /// Seconds in z1…z5 as bucketed at ingest — the exact figures, not a count
    /// of the buckets currently on screen.
    let zoneSeconds: [Double]?
    /// What `StreamPlot` needs to lay this metric out.
    let plotMetric: StreamPlot.Metric
    /// The stream as the trace draws it (`StreamPlot.runs`), derived once: at
    /// 1 Hz, every redraw and window read starting from `values` is too slow.
    let runs: [[StreamPlot.Sample]]

    init(kind: Kind, binSeconds: Int, values: [Double?], reference: Reference? = nil,
         zones: [Double]? = nil, zoneSeconds: [Double]? = nil) {
        self.kind = kind
        self.binSeconds = binSeconds
        self.values = values
        self.reference = reference
        self.zones = zones
        self.zoneSeconds = zoneSeconds
        self.plotMetric = .init(axis: kind.axis, framing: kind.framing, zones: zones,
                                bridgesGaps: kind == .elevation, minSpan: kind.minSpan)
        self.runs = StreamPlot.runs(values: values, binSeconds: binSeconds, metric: plotMetric)
    }

    var id: String { kind.rawValue }
    /// Elapsed seconds the stored bins cover.
    var spanSeconds: Double { Double(values.count * binSeconds) }

    /// The stored bins overlapping an elapsed-time window.
    func bins(in window: ClosedRange<Double>) -> ArraySlice<Double?> {
        let bin = Double(binSeconds)
        let lo = max(Int(window.lowerBound / bin), 0)
        let hi = min(Int((window.upperBound / bin).rounded(.up)), values.count)
        return lo < hi ? values[lo..<hi] : []
    }

    /// The recorded samples in a window, as the trace draws them.
    func samples(in window: ClosedRange<Double>) -> [Double] {
        StreamPlot.samples(runs: runs, in: window)
    }

    /// Elapsed time in one format for the whole workout — `h:mm` once it runs an
    /// hour, `m:ss` below — so two labels side by side never mix the two.
    /// `withSeconds` extends `h:mm` to `h:mm:ss`: a point readout, or an axis
    /// zoomed in below minute ticks.
    func timeLabel(_ seconds: Double, withSeconds: Bool = false) -> String {
        let s = Int(seconds)
        guard spanSeconds >= 3600 else { return String(format: "%d:%02d", s / 60, s % 60) }
        return withSeconds ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
                           : String(format: "%d:%02d", s / 3600, (s % 3600) / 60)
    }

    /// Chart models for a workout's decoded streams, in the sport's display order;
    /// pace sports render the speed stream as pace. `details` supplies the
    /// reference levels the source measured at full stream resolution.
    static func models(from decoded: [WorkoutStreams.Metric: [Double?]], details: [String: Any],
                       family: SportFamily) -> [WorkoutStreamModel] {
        let order: [(WorkoutStreams.Metric, Kind)] = switch family {
        case .bike:
            [(.speed, .speed), (.power, .power), (.heartRate, .heartRate),
             (.cadence, .bikeCadence), (.elevation, .elevation)]
        case .run:
            [(.speed, .runPace), (.heartRate, .heartRate), (.power, .power),
             (.cadence, .runCadence), (.elevation, .elevation)]
        case .swim:
            [(.speed, .swimPace), (.heartRate, .heartRate)]
        case .strength:
            [(.heartRate, .heartRate)]
        case .other:
            (SportFamily.matches(storedSport: details["sport"] as? String ?? "", filter: "hiking")
                ? [(.speed, .hikePace)] : [])
            + [(.heartRate, .heartRate), (.elevation, .elevation)]
        }
        return order.compactMap { metric, kind in
            decoded[metric].map {
                WorkoutStreamModel(kind: kind, binSeconds: WorkoutStreams.binSeconds, values: $0,
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
    /// stream, so it is read here, never recomputed from the stored stream.
    private static func reference(_ kind: Kind, _ details: [String: Any]) -> Reference? {
        guard kind == .power,
              let np = Coerce.double((details["cycling"] as? [String: Any])?["normalized_power_w"]),
              np > 0
        else { return nil }
        return Reference(value: np, label: "NP")
    }

    /// Race-wide models for a multisport session: every leg's decoded bins placed
    /// on one elapsed-race timeline (a leg's gap between end and the next start
    /// stays nil, so the line breaks there). Only heart rate and elevation
    /// combine — cadence, power and pace mean different things per discipline,
    /// so one series across the legs would be a number that never existed.
    static func raceModels(legs: [(offset: Double, metrics: [WorkoutStreams.Metric: [Double?]])])
        -> [WorkoutStreamModel] {
        let bin = WorkoutStreams.binSeconds
        let span: Double = legs.map { leg in
            leg.offset + Double((leg.metrics.values.first?.count ?? 0) * bin)
        }.max() ?? 0
        guard span > 0 else { return [] }
        let count = Int((span / Double(bin)).rounded(.up))

        return [(WorkoutStreams.Metric.heartRate, Kind.heartRate), (.elevation, .elevation)]
            .compactMap { metric, kind in
                var sums = [Double](repeating: 0, count: count)
                var hits = [Int](repeating: 0, count: count)
                for leg in legs {
                    guard let values = leg.metrics[metric] else { continue }
                    for (i, value) in values.enumerated() {
                        guard let value else { continue }
                        let center = leg.offset + (Double(i) + 0.5) * Double(bin)
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
        case .runPace, .hikePace, .swimPace: "Pace"
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
        case .hikePace: Theme.Palette.sport(.other)
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
    /// than 33 min/km running, 50 min/km hiking (a steep climb runs well below
    /// the running floor), 8:20 /100m swimming.
    var axis: StreamPlot.Axis {
        switch self {
        case .runPace: .inverse(scale: 1000, floor: 0.5)
        case .hikePace: .inverse(scale: 1000, floor: 1 / 3)
        case .swimPace: .inverse(scale: 100, floor: 0.2)
        case .speed: .linear(3.6)
        default: .linear(1)
        }
    }

    /// Whether the stream is speed in m/s — pace kinds store speed too — and so
    /// integrates to a distance.
    var isSpeed: Bool { [.speed, .runPace, .hikePace, .swimPace].contains(self) }

    /// The narrowest span the axis frames, in plot units — a steady stretch
    /// stays a steady line instead of filling the plot.
    var minSpan: Double {
        switch self {
        case .heartRate: 30
        case .elevation: 50
        case .runPace: 60
        case .hikePace: 120
        case .swimPace: 20
        default: 0
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
        case .runPace, .hikePace, .swimPace: Self.pace(display)
        default: "\(Int(display.rounded()))"
        }
    }

    var unit: String {
        switch self {
        case .speed: "km/h"
        case .power: "W"
        case .heartRate: "bpm"
        case .runPace, .hikePace: "/km"
        case .swimPace: "/100m"
        case .bikeCadence: "rpm"
        case .runCadence: "spm"
        case .elevation: "m"
        }
    }

    /// The number the axis shows for a natural-unit value, with a decimal for
    /// speed, where whole km/h is coarse.
    func number(_ value: Double) -> String {
        let plotted = axis.display(value)
        return self == .speed ? String(format: "%.1f", plotted) : axisLabel(plotted)
    }

    /// Tooltip formatting: the number plus its unit.
    func format(_ value: Double) -> String { number(value) + " " + unit }

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

        /// One step of the zoom buttons, shortcuts and double-click.
        static let step = 1.8

        /// Re-centre on `centre` — the pointer on a double-click, otherwise the
        /// midpoint, so a zoom keeps what you were looking at.
        mutating func zoom(to span: Double, around centre: Double? = nil) {
            let centre = centre ?? start + self.span / 2
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

    /// What the pointer reads on the trace, for a host that shows it in its own
    /// readout — the chart then draws the rule without its tooltip.
    struct Reading: Equatable {
        let vertex: StreamPlot.Vertex
        /// The overlay's value at the same moment, natural units.
        let overlay: Double?
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
    let reading: Binding<Reading?>?

    @State private var scrubOffset: Double?
    @Environment(\.routeCursor) private var routeCursor
    @Environment(\.routeCursorBase) private var routeCursorBase
    /// The plot rectangle itself: its width sets the smoothing bucket, its
    /// height keeps the zone ribbon a constant thickness instead of a share of
    /// however tall the chart happens to be.
    @State private var plotSize: CGSize = .zero
    /// Where the running drag/pinch began — a gesture reports against its own
    /// start, not against the window it last produced.
    @State private var panStart: Double?
    @State private var pinchStart: Double?
    /// The axis held still while a gesture runs, so it does not twitch under the
    /// finger; it eases onto the new window once the gesture ends.
    @State private var heldDomain: StreamPlot.Domain?
    /// Whether the pointer is down on the zone ribbon rather than the trace.
    @State private var onRibbon = false
    /// The geometry, keyed by what it depends on — a pointer move changes none
    /// of it, and every hover redraws `body`.
    @State private var plotMemo = Memo<PlotKey, (segments: [StreamPlot.Segment], runs: [StreamPlot.Run])>()
    @State private var domainMemo = Memo<PlotKey, StreamPlot.Domain>()
    @State private var overlayMemo = Memo<OverlayKey, Overlaid>()

    private struct PlotKey: Equatable {
        let model: WorkoutStreamModel
        let window: ClosedRange<Double>
        let width: Double
    }

    private struct OverlayKey: Equatable {
        let plot: PlotKey
        let target: StreamPlot.Domain
    }

    /// The zone ribbon's thickness in points — constant, so a tall plot does not
    /// hand it more of the chart than it needs — and the taller strip that counts
    /// as touching it, since 6 pt is a poor finger target.
    private static let ribbonPoints = 6.0
    private static let ribbonTouchPoints = 26.0

    init(model: WorkoutStreamModel, overlay: WorkoutStreamModel? = nil, bands: [Band] = [],
         height: CGFloat? = 140, zoom: Binding<Zoom>? = nil,
         highlight: Binding<Int?>? = nil, reading: Binding<Reading?>? = nil) {
        self.model = model
        self.overlay = overlay
        self.bands = bands
        self.height = height
        self.zoom = zoom
        self.highlight = highlight
        self.reading = reading
    }

    var body: some View {
        Group {
            if let zoom {
                chart
                    #if os(iOS)
                    .gesture(HorizontalPan(onChange: pan))
                    .simultaneousGesture(pinch)
                    #else
                    .gesture(DragGesture(minimumDistance: 10)
                        .onChanged { pan($0.translation.width) }
                        .onEnded { _ in pan(nil) }
                        .simultaneously(with: pinch))
                    #endif
                    #if os(macOS)
                    .overlay { HorizontalScroll(onChange: pan) }
                    #endif
                    .onTapGesture(count: 2) {
                        withAnimation(.snappy) {
                            zoom.wrappedValue.zoom(to: zoom.wrappedValue.span / Zoom.step, around: scrubOffset)
                        }
                    }
            } else {
                chart
            }
        }
        // After the update, never during it: the zone is derived from the same
        // bucketing the marks are drawn from.
        .onChange(of: highlightedZone) { _, zone in highlight?.wrappedValue = zone }
        .onChange(of: onRibbon ? nil : scrubOffset) { _, offset in
            reading?.wrappedValue = offset.flatMap(read(at:))
            routeCursor?.offset = offset.map { $0 + routeCursorBase }
        }
    }

    private var window: ClosedRange<Double> { zoom?.wrappedValue.window ?? 0...model.spanSeconds }
    private var visibleSpan: Double { zoom?.wrappedValue.span ?? model.spanSeconds }
    /// The axis follows the visible stretch, never narrower than the kind's
    /// `minSpan`.
    private var yDomain: StreamPlot.Domain {
        heldDomain ?? domainMemo(plotKey) {
            StreamPlot.domain(values: model.bins(in: window), metric: model.plotMetric)
        }
    }

    private var plotKey: PlotKey { PlotKey(model: model, window: window, width: plotWidth) }

    private func hold(_ holding: Bool) {
        if holding {
            if heldDomain == nil { heldDomain = yDomain }
        } else if panStart == nil, pinchStart == nil {
            withAnimation(.snappy) { heldDomain = nil }
        }
    }
    /// Before the first geometry pass a phone-ish width stands in, so the first
    /// frame draws a sane trace instead of an empty plot.
    private var plotWidth: Double { plotSize.width > 0 ? plotSize.width : 320 }

    private func overlaid(into domain: StreamPlot.Domain) -> Overlaid? {
        overlay.map { overlay in
            overlayMemo(OverlayKey(plot: PlotKey(model: overlay, window: window, width: plotWidth),
                                   target: domain)) {
                Overlaid(overlay, window: window, plotWidth: plotWidth, into: domain)
            }
        }
    }

    private func read(at offset: Double) -> Reading? {
        guard let vertex = StreamPlot.nearest(to: offset, in: plot.segments) else { return nil }
        return Reading(vertex: vertex, overlay: overlaid(into: yDomain).flatMap {
            StreamPlot.nearest(to: vertex.offset, in: $0.segments)?.mean
        })
    }

    /// The bucketing this pass renders, and the zone stretches over it.
    private var plot: (segments: [StreamPlot.Segment], runs: [StreamPlot.Run]) {
        plotMemo(plotKey) {
            let segments = StreamPlot.segments(
                runs: model.runs, binSeconds: model.binSeconds, metric: model.plotMetric,
                visibleSpan: visibleSpan, plotWidth: plotWidth, in: window)
            return (segments, StreamPlot.zoneRuns(of: segments))
        }
    }

    /// The zone under the pointer, but only while it rests on the ribbon —
    /// scrubbing the trace itself reads values, not zones.
    private var highlightedZone: Int? {
        guard onRibbon, let offset = scrubOffset else { return nil }
        return plot.runs.first { offset >= $0.start && offset <= $0.end }?.zone
    }

    /// Drag to pan. A scrollable chart would be the framework's own answer, but
    /// it only pans on a *horizontal* scroll event — which a plain mouse never
    /// sends. Converting the drag through the measured plot width instead means
    /// the trace follows the finger or cursor one-to-one everywhere. Nil ends it.
    private func pan(_ translation: CGFloat?) {
        guard let zoom else { return }
        guard let translation else { panStart = nil; hold(false); return }
        #if os(iOS)
        // A long press that is already scrubbing owns the finger. macOS scrubs
        // on hover, which is never a drag, so it never competes.
        guard scrubOffset == nil || panStart != nil else { return }
        #endif
        hold(true)
        let from = panStart ?? zoom.wrappedValue.start
        panStart = from
        zoom.wrappedValue.pan(from: from,
                              bySeconds: -translation / max(plotSize.width, 1) * zoom.wrappedValue.span)
    }

    private var pinch: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                guard let zoom else { return }
                hold(true)
                let base = pinchStart ?? zoom.wrappedValue.span
                pinchStart = base
                zoom.wrappedValue.zoom(to: base / value.magnification)
            }
            .onEnded { _ in pinchStart = nil; hold(false) }
    }

    private var chart: some View {
        let (segments, runs) = plot
        let yDomain = self.yDomain
        let overlaid = self.overlaid(into: yDomain)
        return Chart {
            if let overlaid {
                ForEach(overlaid.segments) { segment in
                    ForEach(segment.vertices) { vertex in
                        AreaMark(x: .value("Time", vertex.offset),
                                 yStart: .value(overlaid.model.kind.label, overlaid.base),
                                 yEnd: .value(overlaid.model.kind.label, overlaid.scale(vertex.plot)),
                                 series: .value("Overlay", "o\(segment.id)"))
                            .foregroundStyle(.linearGradient(
                                colors: [overlaid.model.kind.color.opacity(0.35),
                                         overlaid.model.kind.color.opacity(0.06)],
                                startPoint: .top, endPoint: .bottom))
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
            zoneMarks(runs, in: yDomain)
            referenceMark
            scrubMarks(in: segments)
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
            let ticks = StreamPlot.timeTicks(in: window)
            AxisMarks(values: ticks.values) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let seconds = value.as(Double.self) {
                        Text(model.timeLabel(seconds, withSeconds: ticks.step < 60))
                    }
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
    @ChartContentBuilder private func zoneMarks(_ runs: [StreamPlot.Run],
                                                in yDomain: StreamPlot.Domain) -> some ChartContent {
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
    private func scrubMarks(in segments: [StreamPlot.Segment]) -> some ChartContent {
        if let offset = scrubOffset, highlightedZone == nil,
           let vertex = StreamPlot.nearest(to: offset, in: segments) {
            let rule = RuleMark(x: .value("Scrub", vertex.offset))
                .foregroundStyle(.secondary.opacity(0.6))
                .lineStyle(StrokeStyle(lineWidth: 1))
            if reading != nil {
                rule
            } else {
                rule.annotation(position: .top, spacing: 0,
                            overflowResolution: .init(x: .fit(to: .plot), y: .fit(to: .plot))) {
                    ChartTooltip(title: model.timeLabel(vertex.offset, withSeconds: true),
                                 rows: tooltipRows(vertex))
                }
            }
        }
    }

    /// The bucket's mean and the raw spread it averaged away.
    private func tooltipRows(_ vertex: StreamPlot.Vertex) -> [ChartTooltip.Row] {
        var rows = [ChartTooltip.Row(color: model.kind.color, label: model.kind.label,
                                     value: model.kind.format(vertex.mean))]
        if vertex.plotLow < vertex.plotHigh {
            rows.append(.init(color: nil, label: "Range",
                              value: model.kind.rangeText(vertex.low, vertex.high)))
        }
        return rows
    }

    /// The overlay, bucketed on the same grid as the trace and mapped from its
    /// own domain into the bottom band of the primary's — terrain under the
    /// trace, not a second trace competing with it. Deliberately no second Y
    /// axis: two metrics on one plot are not comparable, and an axis would
    /// imply they are.
    private struct Overlaid {
        let model: WorkoutStreamModel
        let segments: [StreamPlot.Segment]
        let scale: StreamPlot.Rescale
        /// The floor the silhouette fills from.
        let base: Double
        /// The share of the plot's height the silhouette rises to.
        private static let band = 0.55

        init(_ model: WorkoutStreamModel, window: ClosedRange<Double>, plotWidth: Double,
             into target: StreamPlot.Domain) {
            self.model = model
            self.segments = StreamPlot.segments(runs: model.runs, binSeconds: model.binSeconds,
                                                metric: model.plotMetric,
                                                visibleSpan: window.upperBound - window.lowerBound,
                                                plotWidth: plotWidth, in: window)
            let source = StreamPlot.domain(values: model.bins(in: window), metric: model.plotMetric)
            let top = target.fromFloor(Self.band)
            self.base = target.floor
            // A pace overlay keeps its fastest at the top, as on its own axis.
            self.scale = StreamPlot.Rescale(
                source: source,
                target: source.reversed ? .init(lo: top, hi: base, reversed: false)
                                        : .init(lo: base, hi: top, reversed: false))
        }
    }
}

#if os(iOS)
/// A pan that only begins on a mostly horizontal drag. A SwiftUI drag claims
/// every touch ahead of an enclosing ScrollView, so a vertical swipe over the
/// plot could not scroll the page; a UIKit recognizer that declines to begin
/// leaves it to the scroll view. Reports the horizontal translation, nil on end.
private struct HorizontalPan: UIGestureRecognizerRepresentable {
    let onChange: (CGFloat?) -> Void

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        return pan
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        switch recognizer.state {
        case .began, .changed: onChange(recognizer.translation(in: recognizer.view).x)
        default: onChange(nil)
        }
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return true }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.x) > abs(velocity.y)
        }
    }
}
#endif

#if os(macOS)
/// Horizontal trackpad or wheel scrolling over the plot, reported like a drag:
/// the translation so far, nil on end. SwiftUI surfaces no scroll-wheel event,
/// so an AppKit view takes it — hit-testable for scroll events only, so hover
/// and clicks fall through to the chart, and a vertical scroll passes on to the
/// page. The direction is locked per gesture so one swipe never does both.
private struct HorizontalScroll: NSViewRepresentable {
    let onChange: (CGFloat?) -> Void

    func makeNSView(context: Context) -> ScrollCatcher { ScrollCatcher() }
    func updateNSView(_ view: ScrollCatcher, context: Context) { view.onChange = onChange }

    final class ScrollCatcher: NSView {
        var onChange: (CGFloat?) -> Void = { _ in }
        private var horizontal: Bool?
        private var total: CGFloat = 0

        override func hitTest(_ point: NSPoint) -> NSView? {
            NSApp.currentEvent?.type == .scrollWheel ? super.hitTest(point) : nil
        }

        override func scrollWheel(with event: NSEvent) {
            // A plain mouse wheel sends phase-less ticks, each its own gesture.
            let tick = event.phase.isEmpty && event.momentumPhase.isEmpty
            if tick || event.phase == .began || event.momentumPhase == .began {
                horizontal = nil
                total = 0
            }
            if horizontal == nil, event.scrollingDeltaX != 0 || event.scrollingDeltaY != 0 {
                horizontal = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
            }
            guard horizontal == true else { return super.scrollWheel(with: event) }
            total += event.scrollingDeltaX
            onChange(total)
            if tick || [.ended, .cancelled].contains(event.phase)
                || [.ended, .cancelled].contains(event.momentumPhase) {
                onChange(nil)
            }
        }
    }
}
#endif
