import SwiftUI

/// One PMC value as a compact tile — `PMCStatTiles` below builds the CTL / ATL / TSB
/// trio both screens show. `status` is the dashboard's extra read of the value; the
/// analysis screen shows the number alone. The tile fills whatever height its row or
/// column offers, so a group of them reads as one block rather than three floating
/// boxes.
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
        .frame(maxHeight: .infinity)
        .glassCard(padding: Theme.Spacing.m)
    }
}

/// The CTL / ATL / TSB tiles as one block. The dashboard's Fitness & Form section
/// and the Statistics PMC section show the same three numbers, so their names,
/// acronyms, colours and rounding live here — a column beside the chart where there
/// is room, a row above it on the phone.
struct PMCStatTiles: View {
    /// One entry per metric, in CTL / ATL / TSB order.
    struct Triple<Value> {
        var ctl: Value, atl: Value, tsb: Value
    }

    let result: PMCResult
    /// The dashboard's per-value read ("Declining", "Fresh", …).
    var statuses: Triple<String>?

    private var wide = WideLayout()

    var body: some View {
        if let s = result.snapshot {
            wide.tiles {
                tile("Fitness", "CTL", .blue, s.ctl, statuses?.ctl) { $0.ctl }
                tile("Fatigue", "ATL", .pink, s.atl, statuses?.atl) { $0.atl }
                tile("Form", "TSB", .orange, s.tsb, statuses?.tsb) { $0.tsb }
            }
            .frame(width: wide.tileColumnWidth)
            .frame(maxHeight: wide.rowHeight)
        }
    }

    /// Both screens show the same weekly change, so the tiles look it up themselves.
    private func tile(_ title: String, _ caption: String, _ dot: Color,
                      _ value: Double, _ status: String?,
                      _ metric: (PMCPoint) -> Double) -> some View {
        PMCStatCard(title: title, caption: caption, dot: dot,
                    value: Int(value.rounded()),
                    delta: result.delta(daysAgo: 7, metric), status: status)
    }
}
