import SwiftUI

// MARK: - Zone distribution bar
//
// Time-in-zone (Z1…Z5) as a titled `SegmentBar`. The model is a plain Codable
// value so any producer (detail view, statistics, a future coach chart tool)
// can feed the same view; colors resolve from `Theme.Palette.zones` by index.

struct ZoneDistributionModel: Codable, Equatable {
    var title: String        // "Heart rate" / "Power"
    var seconds: [Double]    // z1…z5
}

struct ZoneDistributionBar: View {
    let model: ZoneDistributionModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text(model.title).font(.caption).foregroundStyle(.secondary)
            ProportionBar(segments: model.seconds.enumerated().map { index, seconds in
                ProportionBar.Segment(
                    label: "Z\(index + 1)",
                    color: Theme.Palette.zones[min(index, Theme.Palette.zones.count - 1)],
                    value: seconds,
                    display: Self.time(seconds)
                )
            })
        }
    }

    private static func time(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return total >= 60 ? "\(total / 60)m" : "\(total)s"
    }
}
