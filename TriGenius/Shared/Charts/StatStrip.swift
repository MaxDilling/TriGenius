import SwiftUI

/// Labelled figures side by side on one card, split by hairlines — the summary
/// under a detail chart. A `title` names what the figures cover.
struct StatStrip: View {
    var title: String?
    let stats: [(label: String, value: String)]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            if let title { Text(title).font(.caption).foregroundStyle(.secondary) }
            // Two rows once the figures no longer fit one at full size.
            ViewThatFits(in: .horizontal) {
                row(stats.indices)
                let columns = (stats.count + 1) / 2
                VStack(spacing: Theme.Spacing.s) {
                    row(0..<columns)
                    row(columns..<columns * 2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    /// One row of figures; an index past the last stat is an empty column, which
    /// keeps a shorter second row aligned with the first.
    private func row(_ indices: Range<Int>) -> some View {
        HStack(spacing: Theme.Spacing.m) {
            ForEach(indices, id: \.self) { index in
                if index > indices.lowerBound { Divider().opacity(index < stats.count ? 1 : 0) }
                VStack(alignment: .leading, spacing: 2) {
                    if index < stats.count {
                        Text(stats[index].label).font(.caption2).foregroundStyle(.secondary)
                        Text(stats[index].value).font(.subheadline.weight(.semibold)).monospacedDigit()
                            .lineLimit(1).minimumScaleFactor(0.8)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
