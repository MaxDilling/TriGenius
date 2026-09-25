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

    var body: some View {
        WorkoutStreamChart(model: model, bands: bands, height: height)
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
    @Environment(\.windowSize) private var windowSize
    @State private var zoom: WorkoutStreamChart.Zoom
    /// `WorkoutStreamModel.id` of the metric drawn behind the trace, nil for none.
    @State private var overlayID: String?
    /// The zone under the pointer on the chart's ribbon, nil when it is elsewhere.
    @State private var hoveredZone: Int?

    /// One step of the zoom buttons.
    private static let step = 1.8

    init(title: String, model: WorkoutStreamModel, overlays: [WorkoutStreamModel] = [],
         bands: [WorkoutStreamChart.Band] = []) {
        self.title = title
        self.model = model
        self.overlays = overlays
        self.bands = bands
        _zoom = State(initialValue: .init(full: model.spanSeconds, binSeconds: model.binSeconds))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: Theme.Spacing.m) {
                WorkoutStreamChart(model: model, overlay: overlay, bands: bands,
                                   height: nil, zoom: $zoom, highlight: $hoveredZone)
                controls
            }
            .padding(Theme.Spacing.l)
            .navigationTitle(title)
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(macOS)
        // Most of the presenting window. The chart is greedy in both axes, so
        // without an explicit size the sheet grows past the window; with a fixed
        // one it overflows a small window and wastes a large one.
        .frame(width: macSheetSize.width, height: macSheetSize.height)
        #else
        // A frame cannot resize a sheet here — the presentation owns the size —
        // and iPadOS defaults to `.form`, small and centred. `.page` is the one
        // that hands a chart the screen; on iPhone it is the usual sheet.
        .presentationSizing(.page)
        #endif
    }

    #if os(macOS)
    /// Most of the window, and it follows the window when that is resized.
    /// `.zero` only before the root's first layout pass.
    private var macSheetSize: CGSize {
        guard windowSize.width > 0 else { return CGSize(width: 900, height: 600) }
        return CGSize(width: windowSize.width * 0.92, height: windowSize.height * 0.88)
    }
    #endif

    /// The chart itself takes drag and pinch; these are what a mouse has.
    private var controls: some View {
        HStack(spacing: Theme.Spacing.m) {
            Button { zoom.zoom(to: zoom.span * Self.step) } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .disabled(zoom.isFit)
            Button { zoom.zoom(to: zoom.span / Self.step) } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .disabled(!zoom.canZoomIn)
            Button("Fit") { zoom.zoom(to: zoom.full) }
                .disabled(zoom.isFit)
            if !overlays.isEmpty { overlayPicker }
            Spacer(minLength: 0)
            // Left of the total, so naming a zone never shifts it.
            if let hoveredZone, let readout = zoneReadout(hoveredZone) {
                Text(readout)
                    .font(.caption).monospacedDigit().lineLimit(1)
                    .foregroundStyle(Theme.Palette.zones[hoveredZone])
            }
            Text(windowLabel)
                .font(.caption).monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.bordered)
        .font(.body)
    }

    private var overlay: WorkoutStreamModel? {
        overlays.first { $0.id == overlayID }
    }

    /// The second metric behind the trace. Its own scale is gone once it shares
    /// the plot, so the picker states the range it spans and the tooltip carries
    /// its real value at the scrubbed moment.
    @ViewBuilder private var overlayPicker: some View {
        Picker("Behind", selection: $overlayID) {
            Text("No overlay").tag(String?.none)
            ForEach(overlays) { candidate in
                Text(candidate.kind.label).tag(String?.some(candidate.id))
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .fixedSize()
        if let overlay, let range = Self.range(of: overlay) {
            Text(range).font(.caption).foregroundStyle(overlay.kind.color)
        }
    }

    /// The overlay's measured span, in its own units.
    private static func range(of overlay: WorkoutStreamModel) -> String? {
        let values = overlay.values.compactMap { $0 }.filter(overlay.kind.axis.isMoving)
        guard let lo = values.min(), let hi = values.max() else { return nil }
        return overlay.kind.rangeText(lo, hi)
    }

    /// The hovered zone spelled out: what it meant for *this* workout and how
    /// long was spent there — both as bucketed at ingest, so the readout agrees
    /// with the time-in-zone bars rather than counting the buckets on screen.
    private func zoneReadout(_ zone: Int) -> String? {
        guard let metric = model.kind.zoneMetric, let bounds = model.zones else { return nil }
        var parts = ["Z\(zone + 1)"]
        if let range = metric.rangeText(zone: zone, bounds: bounds) { parts.append(range) }
        if let seconds = model.zoneSeconds, zone < seconds.count, seconds[zone] > 0 {
            parts.append(Self.hms(seconds[zone]))
        }
        return parts.joined(separator: " · ")
    }

    private var windowLabel: String {
        zoom.isFit ? Self.hms(zoom.full)
                   : Self.hms(zoom.span) + " of " + Self.hms(zoom.full)
    }

    private static func hms(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return s >= 3600 ? String(format: "%dh %02dm", s / 3600, (s % 3600) / 60)
                         : String(format: "%dm %02ds", s / 60, s % 60)
    }
}
