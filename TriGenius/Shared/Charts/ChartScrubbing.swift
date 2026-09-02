import SwiftUI
import Charts
#if os(iOS)
import UIKit
#endif

// MARK: - Chart scrubbing & tooltip
//
// Shared X-axis scrubbing for every chart (date axes and numeric ones like the
// power curve's log duration), from two inputs at once: long-press-then-drag for
// touch, and pointer hover for the macOS cursor, a trackpad on iPad, and Apple
// Pencil hover. Charts render their own tooltip from the selected value via
// `ChartTooltip`. `horizontalScrubbing` carries the same two inputs to a plain
// (non-Chart) view such as `ProportionBar`.

extension View {
    /// Bind the X value under the finger or pointer — nil when idle.
    /// `snap` quantizes the raw location to the chart's own data grid (nearest
    /// point / containing week); the binding is only written when the snapped
    /// value changes. The scrub rule + tooltip are chart *content*, so every
    /// write re-collects all marks — snapping turns per-pixel pointer events
    /// into one update per data point crossed.
    func chartScrubbing<V: Plottable & Equatable>(_ selection: Binding<V?>, snap: @escaping (V) -> V?) -> some View {
        let snapped = Binding<V?>(
            get: { selection.wrappedValue },
            set: { raw in
                let value = raw.flatMap(snap)
                if value != selection.wrappedValue { selection.wrappedValue = value }
            }
        )
        return chartOverlay { proxy in
            scrubSurface { point in
                snapped.wrappedValue = point.flatMap { proxy.value(atX: $0.x, as: V.self) }
            }
            // Hover never enters the touch stream, so it rides alongside the
            // long-press below it rather than competing with it — a hovering
            // Pencil scrubs, a finger still long-presses.
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    snapped.wrappedValue = proxy.value(atX: location.x, as: V.self)
                case .ended:
                    snapped.wrappedValue = nil
                }
            }
        }
    }
}

/// The plot-covering scrub surface. On iOS a UIKit recognizer, not a SwiftUI
/// gesture: every SwiftUI route (`chartXSelection`, `chartGesture`, a plain overlay
/// `.gesture`) claims the touch ahead of the enclosing ScrollView's pan, so a
/// scroll starting on the plot goes dead. UILongPressGestureRecognizer arbitrates
/// natively with UIScrollView — a swipe cancels it and scrolls; a ~0.2 s hold
/// recognizes, excludes the pan, and tracks the finger to scrub. macOS has no touch
/// to track, so a hit-testable rectangle carries the hover on its own.
@ViewBuilder func scrubSurface(onTouch: @escaping (CGPoint?) -> Void) -> some View {
    #if os(iOS)
    ScrubTouchOverlay(onChange: onTouch)
    #else
    Rectangle().fill(.clear).contentShape(Rectangle())
    #endif
}

#if os(iOS)
/// Clear plot-covering view whose long-press recognizer reports the finger's
/// plot-local position while active — nil on lift, swipe-cancel, or failure.
private struct ScrubTouchOverlay: UIViewRepresentable {
    let onChange: (CGPoint?) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        let press = UILongPressGestureRecognizer(target: context.coordinator,
                                                 action: #selector(Coordinator.handle(_:)))
        press.minimumPressDuration = 0.2
        view.addGestureRecognizer(press)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onChange = onChange
    }

    func makeCoordinator() -> Coordinator { Coordinator(onChange: onChange) }

    final class Coordinator: NSObject {
        var onChange: (CGPoint?) -> Void
        init(onChange: @escaping (CGPoint?) -> Void) { self.onChange = onChange }

        @objc func handle(_ recognizer: UILongPressGestureRecognizer) {
            switch recognizer.state {
            case .began, .changed: onChange(recognizer.location(in: recognizer.view))
            default: onChange(nil)
            }
        }
    }
}
#endif

extension View {
    /// Scrubbing for a plain view: reports the pointer/finger X as a 0…1 fraction of
    /// the view's own width, nil when idle. Same two inputs as `chartScrubbing`, so a
    /// bar inside a ScrollView still scrolls on a swipe and scrubs on a hold.
    /// `hitInset` grows the surface vertically past the view's bounds — a 10 pt bar is
    /// a poor finger target — without touching layout or the width the fraction is of.
    func horizontalScrubbing(_ fraction: Binding<Double?>, hitInset: CGFloat = 0) -> some View {
        overlay {
            GeometryReader { geo in
                let width = geo.size.width
                scrubSurface { point in
                    fraction.wrappedValue = width > 0
                        ? point.map { min(max($0.x / width, 0), 1) }
                        : nil
                }
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        fraction.wrappedValue = width > 0 ? min(max(location.x / width, 0), 1) : nil
                    case .ended:
                        fraction.wrappedValue = nil
                    }
                }
                .padding(.vertical, -hitInset)
            }
        }
    }
}

/// The floating value readout shown at the scrubbed date.
///
/// Anchor it to the plot on **both** axes
/// (`overflowResolution: .init(x: .fit(to: .plot), y: .fit(to: .plot))`): a bubble
/// leaving the plot is clipped by `chartPlotStyle { $0.clipped() }` where a chart
/// sets it, and one overflowing past the enclosing `.glassSurface()` card is
/// composited *under* that card's glass rim, which then draws across it and makes
/// the opaque background look translucent.
struct ChartTooltip: View {
    struct Row: Identifiable {
        let color: Color?
        let label: String
        let value: String
        var id: String { label }
    }

    let title: String
    let rows: [Row]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption2.bold())
            ForEach(rows) { row in
                HStack(spacing: 4) {
                    if let color = row.color {
                        Circle().fill(color).frame(width: 6, height: 6)
                    }
                    Text(row.label).foregroundStyle(.secondary)
                    Text(row.value).monospacedDigit()
                }
                .font(.caption2)
            }
        }
        // Content layer, never glass/material: dense data stays opaque (DESIGN.md §1).
        .cardSurface(cornerRadius: Theme.Radius.s, padding: Theme.Spacing.s)
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous)
            .strokeBorder(.separator))
    }
}
