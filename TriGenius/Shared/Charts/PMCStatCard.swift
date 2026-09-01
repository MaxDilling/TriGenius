import SwiftUI

/// One PMC value as a compact tile. The same three tiles carry the dashboard's
/// Fitness & Form section and the top of the Statistics screen, so the numbers read
/// as the same object across the tap. `caption` (the acronym) and `status` are the
/// dashboard's extra lines — the analysis screen passes neither and gets the short
/// form, at identical padding.
struct PMCStatCard: View {
    let title: String
    var caption: String?
    let dot: Color
    let value: Int
    let delta: Int
    var status: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Circle().fill(dot).frame(width: 7, height: 7)
                Text(title).font(.caption).foregroundStyle(.secondary)
                if let caption {
                    Text("(\(caption))").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(value)").font(.title.bold())
                if delta != 0 {
                    HStack(spacing: 1) {
                        Image(systemName: delta > 0 ? "arrow.up" : "arrow.down")
                        Text("\(abs(delta))")
                    }
                    .font(.caption2).foregroundStyle(dot)
                }
            }
            if let status {
                Text(status).font(.caption2).foregroundStyle(dot)
            }
        }
        .glassCard(padding: Theme.Spacing.m)
    }
}
