import SwiftUI

// MARK: - Zone distribution bar
//
// Time-in-zone (Z1…Z5) as a titled `SegmentBar`. The model is a plain Codable
// value so any producer (detail view, statistics, a future coach chart tool)
// can feed the same view; colors resolve from `Theme.Palette.zones` by index.
//
// Pointing at a zone answers "what does Z5 actually mean for me": the caption line
// becomes that zone's readout — the model (percent of threshold, true whatever the
// athlete's numbers) and, when the bounds are known, the numbers themselves. It
// takes over the line the metric name occupies rather than floating above the bar:
// the bubble would stand taller than the whole bar block and overflow the enclosing
// card.

/// Every metric that has time in it, as titled bars — the shared layout behind the
/// workout detail view, Statistics and the coach's chat card, so a new `ZoneMetric`
/// surfaces in all three at once. Renders nothing when no metric has data; the call
/// site decides what to show instead.
struct ZoneDistributionStack: View {
    let seconds: [ZoneMetric: [Double]]
    /// z1–z4 upper bounds per metric, in the metric's own unit. A metric without them
    /// shows percentages of threshold only.
    var bounds: [ZoneMetric: [Double]] = [:]
    /// Set when `bounds` are *not* the ones these seconds were bucketed against — an
    /// aggregate spans workouts whose thresholds may differ — so the readout can say
    /// which numbers it is showing.
    var boundsNote: String?

    /// Whether any metric has time to show — the call sites' empty-state condition.
    static func isEmpty(_ seconds: [ZoneMetric: [Double]]) -> Bool {
        !seconds.values.contains { $0.contains { $0 > 0 } }
    }

    var body: some View {
        ForEach(ZoneMetric.allCases, id: \.self) { metric in
            if let zones = seconds[metric], zones.contains(where: { $0 > 0 }) {
                ZoneDistributionBar(model: ZoneDistributionModel(
                    metric: metric, seconds: zones,
                    bounds: bounds[metric], boundsNote: boundsNote))
            }
        }
    }
}

struct ZoneDistributionModel: Codable, Equatable {
    var metric: ZoneMetric
    var seconds: [Double]      // z1…z5
    var bounds: [Double]?      // z1–z4 upper bounds, in the metric's own unit
    var boundsNote: String?
}

struct ZoneDistributionBar: View {
    let model: ZoneDistributionModel

    @State private var selection: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            caption
                .font(.caption)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .animation(.easeOut(duration: 0.12), value: selection)
            ProportionBar(
                segments: model.seconds.enumerated().map { index, seconds in
                    ProportionBar.Segment(
                        label: "Z\(index + 1)",
                        color: Theme.Palette.zones[min(index, Theme.Palette.zones.count - 1)],
                        value: seconds,
                        display: Self.time(seconds)
                    )
                },
                selection: $selection
            )
        }
    }

    /// The metric's name, or — while a zone is pointed at — that zone's numbers
    /// followed by the model behind them, so the reading stays interpretable even
    /// with no threshold on file. The time itself stays in the legend below.
    @ViewBuilder private var caption: some View {
        if let zone = selection.flatMap(Self.zoneIndex) {
            HStack(spacing: 5) {
                Text(selection ?? "")
                    .fontWeight(.semibold)
                    .foregroundStyle(Theme.Palette.zones[min(zone, Theme.Palette.zones.count - 1)])
                if let range = model.bounds.flatMap({ model.metric.rangeText(zone: zone, bounds: $0) }) {
                    Text(model.boundsNote.map { "\(range) (\($0))" } ?? range)
                }
                if let fractions = model.metric.fractionText(zone: zone) {
                    Text(fractions).foregroundStyle(.secondary)
                }
            }
        } else {
            Text(model.metric.displayName).foregroundStyle(.secondary)
        }
    }

    private static func zoneIndex(_ label: String) -> Int? {
        Int(label.dropFirst()).flatMap { (1...5).contains($0) ? $0 - 1 : nil }
    }

    private static func time(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return total >= 60 ? durationHM(seconds / 60) : "\(total)s"
    }
}
