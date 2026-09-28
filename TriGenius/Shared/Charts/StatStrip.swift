import SwiftUI

/// Labelled figures side by side on one card, split by hairlines — the summary
/// under a detail chart. A `title` names what the figures cover.
struct StatStrip: View {
    var title: String?
    let stats: [(label: String, value: String)]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            if let title { Text(title).font(.caption).foregroundStyle(.secondary) }
            figures
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    private var figures: some View {
        HStack(spacing: Theme.Spacing.m) {
            ForEach(stats.indices, id: \.self) { index in
                if index > 0 { Divider() }
                VStack(alignment: .leading, spacing: 2) {
                    Text(stats[index].label).font(.caption2).foregroundStyle(.secondary)
                    Text(stats[index].value).font(.subheadline.weight(.semibold)).monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
