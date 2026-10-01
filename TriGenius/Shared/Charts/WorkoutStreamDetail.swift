import SwiftUI

// MARK: - Workout stream card & its zoomable detail
//
// The tappable card every workout-detail trace sits in, and the sheet it opens:
// the same `WorkoutStreamChart` at full size, pinched or stepped to any zoom and
// scrolled along the workout's timeline. Zoom narrows the *visible span*, which
// is exactly what the chart derives its smoothing window from — so pulling in
// uncovers the raw bins rather than magnifying a pre-baked level of detail.

struct WorkoutStreamCard: View {
    let title: String
    let model: WorkoutStreamModel
    /// Every metric of this workout — the card filters itself out and offers the
    /// rest as overlays in the sheet.
    var siblings: [WorkoutStreamModel] = []
    var bands: [WorkoutStreamChart.Band] = []
    var height: CGFloat = 140

    @State private var showDetail = false
    /// The zone pressed on the time-in-zone bar, shaded in the chart above it.
    @State private var zone: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            WorkoutStreamChart(model: model, bands: bands, height: height, shadedZone: zone)
            if let distribution = model.zoneDistribution {
                ZoneDistributionBar(model: distribution, title: "Time in zone", zone: $zone)
            }
        }
        .cardTitle(title) {
            // The card as a whole opens the sheet; the button is the
            // visible affordance, and the one target the plot's own scrub
            // overlay can never swallow.
            Button { showDetail = true } label: {
                Image(systemName: "arrow.down.left.and.arrow.up.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
        .contentShape(Rectangle())
        .onTapGesture { showDetail = true }
        .sheet(isPresented: $showDetail) {
            WorkoutStreamDetail(title: title, model: model,
                                overlays: siblings.filter { $0.id != model.id }, bands: bands)
        }
    }
}

struct WorkoutStreamDetail: View {
    let title: String
    let model: WorkoutStreamModel
    let overlays: [WorkoutStreamModel]
    let bands: [WorkoutStreamChart.Band]

    @Environment(\.dismiss) private var dismiss
    private var wide = WideLayout()
    @State private var zoom: WorkoutStreamChart.Zoom
    /// `WorkoutStreamModel.id` of the metric drawn behind the trace, nil for none.
    @State private var overlayID: String?
    /// The zone under the pointer on the chart's ribbon, nil when it is elsewhere.
    @State private var hoveredZone: Int?
    /// What the pointer reads on the trace, nil when it is elsewhere.
    @State private var reading: WorkoutStreamChart.Reading?
    /// The page's visible height, and everything on it but the chart — the chart
    /// takes the difference, so it fills a tall window and keeps `minChartHeight`
    /// in a short one (a phone in landscape), where the page scrolls instead.
    @State private var viewport: CGFloat = 0
    @State private var rest: CGFloat = 0
    /// The window's figures change with the window, not with the pointer.
    @State private var summaryMemo = Memo<SummaryKey, [(label: String, value: String)]>()

    private struct SummaryKey: Equatable {
        let window: ClosedRange<Double>
        let metrics: [WorkoutStreamModel]
    }

    private static let minChartHeight: CGFloat = 240

    init(title: String, model: WorkoutStreamModel, overlays: [WorkoutStreamModel] = [],
         bands: [WorkoutStreamChart.Band] = []) {
        self.title = title
        self.model = model
        self.overlays = overlays
        self.bands = bands
        _zoom = State(initialValue: .init(full: model.spanSeconds, binSeconds: model.binSeconds))
    }

    private var chartHeight: CGFloat { max(Self.minChartHeight, viewport - rest) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                    HStack(alignment: .top) {
                        readout
                        Spacer(minLength: 0)
                        controls
                    }
                    WorkoutStreamChart(model: model, overlay: overlay, bands: bands,
                                       height: chartHeight, zoom: $zoom,
                                       highlight: $hoveredZone, reading: $reading)
                    let stats = summary
                    if !stats.isEmpty { StatStrip(title: "Visible range", stats: stats) }
                }
                .padding(Theme.Spacing.l)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                    rest = $0 - chartHeight
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .onGeometryChange(for: CGFloat.self) {
                $0.size.height - $0.safeAreaInsets.top - $0.safeAreaInsets.bottom
            } action: { viewport = $0 }
            .navigationTitle(title)
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { dismiss() }
                }
            }
        }
        .windowFillingSheet()
    }

    /// Health-style readout: the value under the pointer, else the visible
    /// window's summary (`Kind.summary`) — and, on the zone ribbon, that zone spelled
    /// out. The overlay's legend sits right under the value, since its scale left with
    /// its axis.
    private var readout: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Circle().fill(model.kind.color).frame(width: 9, height: 9)
                Text((reading?.vertex.mean ?? model.kind.summary(model.samples(in: zoom.window)))
                        .map(model.kind.number) ?? "—")
                    .font(.largeTitle.bold()).monospacedDigit()
                Text(model.kind.unit).font(.subheadline).foregroundStyle(.secondary)
            }
            if let overlay {
                HStack(spacing: 6) {
                    Circle().fill(overlay.kind.color).frame(width: 8, height: 8)
                    Text(overlay.kind.label)
                    if let value = reading?.overlay.map(overlay.kind.format) ?? span(of: overlay) {
                        Text(value).foregroundStyle(.secondary)
                    }
                }
                .font(.subheadline).monospacedDigit().lineLimit(1)
            }
            Group {
                if let hoveredZone, let zone = zoneReadout(hoveredZone) {
                    Text(zone).foregroundStyle(Theme.Palette.zones[hoveredZone])
                } else if let reading {
                    Text("At " + model.timeLabel(reading.vertex.offset, withSeconds: true))
                } else {
                    let withSeconds = StreamPlot.timeTicks(in: zoom.window).step < 60
                    Text(model.kind.summaryLabel + " · " + model.timeLabel(zoom.window.lowerBound, withSeconds: withSeconds)
                         + "–" + model.timeLabel(zoom.window.upperBound, withSeconds: withSeconds))
                }
            }
            .font(.subheadline).monospacedDigit().lineLimit(1)
            .foregroundStyle(.secondary)
        }
    }

    /// The visible stretch across the workout's other metrics — zoom onto the
    /// climb and read what it cost. The trace's own summary heads the sheet;
    /// elevation has no meaningful one.
    private var summary: [(label: String, value: String)] {
        let window = zoom.window
        return summaryMemo(SummaryKey(window: window, metrics: [model] + overlays)) {
            var stats: [(label: String, value: String)] = []
            if let speed = ([model] + overlays).first(where: \.kind.isSpeed) {
                let metres = StreamPlot.distance(speeds: speed.values, binSeconds: speed.binSeconds,
                                                 in: window)
                stats.append(("Distance", speed.kind == .swimPace || metres < 1000
                                          ? "\(Int(metres.rounded())) m"
                                          : String(format: "%.2f km", metres / 1000)))
            }
            for other in overlays where other.kind != .elevation {
                if let value = other.kind.summary(other.samples(in: window)) {
                    stats.append((other.kind == .wPrimeBalance ? "Lowest W′" : other.kind.label,
                                  other.kind.format(value)))
                }
            }
            return stats
        }
    }

    private var overlay: WorkoutStreamModel? {
        overlays.first { $0.id == overlayID }
    }

    /// What the silhouette spans over the window: the overlay's extremes, a pace
    /// clipped at the 98th percentile like its axis, so a walk break does not
    /// set the slow end.
    private func span(of overlay: WorkoutStreamModel) -> String? {
        let axis = overlay.kind.axis
        let sorted = overlay.samples(in: zoom.window).sorted { axis.display($0) < axis.display($1) }
        guard let lo = sorted.first, let last = sorted.last else { return nil }
        let hi = axis.isInverting ? sorted[Int(0.98 * Double(sorted.count - 1))] : last
        return overlay.kind.rangeText(lo, hi)
    }

    /// The overlay picker and — where a mouse needs them — the zoom steps, as
    /// glass pills of one height.
    private var controls: some View {
        HStack(spacing: Theme.Spacing.s) {
            if !overlays.isEmpty {
                Menu {
                    Picker("Overlay", selection: $overlayID) {
                        Text("No overlay").tag(String?.none)
                        ForEach(overlays) { candidate in
                            Text(candidate.kind.label).tag(String?.some(candidate.id))
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Image(systemName: "square.2.layers.3d")
                        .foregroundStyle(overlay?.kind.color ?? .primary)
                        .headerSegment()
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .headerPill()
            }
            if wide.isWide {
                HStack(spacing: 0) {
                    zoomSegment(Image(systemName: "minus.magnifyingglass"), shortcut: "-",
                                disabled: zoom.isFit) { zoom.zoom(to: zoom.span * WorkoutStreamChart.Zoom.step) }
                    zoomSegment(Text("Fit"), shortcut: "0", disabled: zoom.isFit) { zoom.zoom(to: zoom.full) }
                    zoomSegment(Image(systemName: "plus.magnifyingglass"), shortcut: "+",
                                disabled: !zoom.canZoomIn) { zoom.zoom(to: zoom.span / WorkoutStreamChart.Zoom.step) }
                }
                .buttonStyle(.plain)
                .headerPill()
            }
        }
    }

    /// One step of the zoom pill, the change animated.
    private func zoomSegment(_ label: some View, shortcut: KeyEquivalent, disabled: Bool,
                             action: @escaping () -> Void) -> some View {
        Button { withAnimation(.snappy, action) } label: { label.headerSegment() }
        .keyboardShortcut(shortcut)
        .disabled(disabled)
    }

    /// The hovered zone spelled out: what it meant for *this* workout and how
    /// long was spent there — both as bucketed at ingest, so the readout agrees
    /// with the workout's time-in-zone bars rather than counting the buckets on
    /// screen.
    private func zoneReadout(_ zone: Int) -> String? {
        guard let metric = model.kind.zoneMetric, let bounds = model.zones else { return nil }
        var parts = ["Z\(zone + 1)"]
        if let range = metric.rangeText(zone: zone, bounds: bounds) { parts.append(range) }
        if let seconds = model.zoneSeconds, zone < seconds.count, seconds[zone] > 0 {
            let s = Int(seconds[zone].rounded())
            parts.append(s >= 3600 ? String(format: "%dh %02dm", s / 3600, (s % 3600) / 60)
                                   : String(format: "%dm %02ds", s / 60, s % 60))
        }
        return parts.joined(separator: " · ")
    }
}
