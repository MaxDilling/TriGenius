import SwiftUI
import Charts
#if os(iOS)
import UIKit
#endif

// MARK: - Chart scrubbing & tooltip
//
// Shared X-axis scrubbing for every chart (date axes and numeric ones like the
// power curve's log duration): long-press-then-drag on iOS (`chartGesture`),
// pointer hover on macOS (where a hit-testable overlay would block nothing else —
// these charts carry no other gestures). Charts render their own tooltip from the
// selected value via `ChartTooltip`.

extension View {
    /// Bind the X value under the finger (iOS) or pointer (macOS) — nil when idle.
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
        #if os(macOS)
        return chartOverlay { proxy in
            Rectangle().fill(.clear).contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        snapped.wrappedValue = proxy.value(atX: location.x, as: V.self)
                    case .ended:
                        snapped.wrappedValue = nil
                    }
                }
        }
        #else
        // A UIKit recognizer, not a SwiftUI gesture: every SwiftUI route
        // (`chartXSelection`, `chartGesture`, a plain overlay `.gesture`) claims
        // the touch ahead of the enclosing ScrollView's pan, so a scroll starting
        // on the plot goes dead. UILongPressGestureRecognizer arbitrates natively
        // with UIScrollView — a swipe cancels it and scrolls; a ~0.2 s hold
        // recognizes, excludes the pan, and tracks the finger to scrub.
        return chartOverlay { proxy in
            ScrubTouchOverlay { point in
                snapped.wrappedValue = point.flatMap { proxy.value(atX: $0.x, as: V.self) }
            }
        }
        #endif
    }
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

/// The floating value readout shown at the scrubbed date.
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
        .padding(Theme.Spacing.s)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous))
    }
}
