import SwiftUI

// MARK: - Proportion bar
//
// A proportional capsule of colored segments plus an optional legend row — the
// shared building block behind time-in-zone bars and the dashboard's sport-share
// mini chart. Pure presentation: callers supply label/color/value per segment, and
// bind `selection` to learn which segment is under the pointer.

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
    /// Label of the segment under the pointer. Bind to opt into scrubbing; nil leaves
    /// the bar inert. The readout itself is the caller's — this only reports what is
    /// being pointed at.
    var selection: Binding<String?>?

    @State private var scrubFraction: Double?

    private var visible: [Segment] { segments.filter { $0.value > 0 } }

    var body: some View {
        let total = max(1, visible.reduce(0) { $0 + $1.value })
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            GeometryReader { geo in
                let widths = renderedWidths(total: total, in: geo.size.width)
                HStack(spacing: Self.gap) {
                    ForEach(Array(visible.enumerated()), id: \.element.id) { index, segment in
                        segment.color.frame(width: widths[index])
                    }
                }
                .onChange(of: scrubFraction) { _, fraction in
                    selection?.wrappedValue = fraction.flatMap { select($0, widths: widths) }
                }
            }
            .frame(height: 10)
            .clipShape(Capsule())
            .modifier(ScrubbingIfBound(fraction: $scrubFraction, enabled: selection != nil))
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

    private static let gap: CGFloat = 1

    /// The widths actually drawn — `max(2, …)` keeps a sliver visible, so hit-testing
    /// reuses them rather than the raw proportions it would otherwise disagree with.
    private func renderedWidths(total: Double, in width: CGFloat) -> [CGFloat] {
        visible.map { max(2, width * $0.value / total) }
    }

    /// The segment covering `fraction` of the bar's width.
    private func select(_ fraction: Double, widths: [CGFloat]) -> String? {
        let span = widths.reduce(0, +) + Self.gap * CGFloat(max(0, widths.count - 1))
        guard span > 0 else { return nil }
        let x = CGFloat(fraction) * span
        var start: CGFloat = 0
        for (index, width) in widths.enumerated() {
            if x <= start + width || index == widths.count - 1 { return visible[index].label }
            start += width + Self.gap
        }
        return nil
    }
}

/// `horizontalScrubbing` installs a hit-testable overlay, which would swallow taps
/// meant for whatever encloses an inert bar — so it goes on only when a caller asked.
private struct ScrubbingIfBound: ViewModifier {
    @Binding var fraction: Double?
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled { content.horizontalScrubbing($fraction, hitInset: 8) } else { content }
    }
}
