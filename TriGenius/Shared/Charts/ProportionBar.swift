import SwiftUI

// MARK: - Proportion bar
//
// A proportional capsule of colored segments plus an optional legend row — the
// shared building block behind time-in-zone bars and the dashboard's sport-share
// mini chart. Pure presentation: callers supply label/color/value per segment.

struct ProportionBar: View {

    struct Segment: Identifiable {
        let label: String
        let color: Color
        let value: Double
        let display: String
        var id: String { label }
    }

    let segments: [Segment]
    var showLegend = true

    private var visible: [Segment] { segments.filter { $0.value > 0 } }

    var body: some View {
        let total = max(1, visible.reduce(0) { $0 + $1.value })
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            GeometryReader { geo in
                HStack(spacing: 1) {
                    ForEach(visible) { segment in
                        segment.color
                            .frame(width: max(2, geo.size.width * segment.value / total))
                    }
                }
            }
            .frame(height: 10)
            .clipShape(Capsule())
            if showLegend {
                HStack(spacing: Theme.Spacing.m) {
                    ForEach(visible) { segment in
                        HStack(spacing: 3) {
                            Circle().fill(segment.color).frame(width: 7, height: 7)
                            Text(segment.label).font(.caption2).foregroundStyle(.secondary)
                            Text(segment.display).font(.caption2).monospacedDigit()
                        }
                    }
                }
            }
        }
    }
}
