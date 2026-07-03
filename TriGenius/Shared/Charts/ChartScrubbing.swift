import SwiftUI
import Charts

// MARK: - Chart scrubbing & tooltip
//
// Shared date-scrubbing for every chart with a date X-axis: touch/drag selection
// on iOS (`chartXSelection`), pointer hover on macOS (where a hit-testable
// overlay would block nothing else — these charts carry no other gestures).
// Charts render their own tooltip from the selected date via `ChartTooltip`.

extension View {
    /// Bind the date under the finger (iOS) or pointer (macOS) — nil when idle.
    /// `snap` quantizes the raw location to the chart's own data grid (nearest
    /// point / containing week); the binding is only written when the snapped
    /// value changes. The scrub rule + tooltip are chart *content*, so every
    /// write re-collects all marks — snapping turns per-pixel pointer events
    /// into one update per data point crossed.
    func chartDateScrubbing(_ selection: Binding<Date?>, snap: @escaping (Date) -> Date?) -> some View {
        let snapped = Binding<Date?>(
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
                        snapped.wrappedValue = proxy.value(atX: location.x, as: Date.self)
                    case .ended:
                        snapped.wrappedValue = nil
                    }
                }
        }
        #else
        return chartXSelection(value: snapped)
        #endif
    }
}

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
