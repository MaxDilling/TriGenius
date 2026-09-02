import SwiftUI

/// One PMC value as a compact tile — `PMCStatTiles` below builds the CTL / ATL / TSB
/// trio both screens show. The tile fills whatever height its row or column offers,
/// so a group of them reads as one block rather than three floating boxes.
struct PMCStatCard: View {
    let title: String
    var caption: String?
    let dot: Color
    let value: Int
    let delta: Int
    let status: String

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
            Text(status).font(.caption2).foregroundStyle(dot)
        }
        .frame(maxHeight: .infinity)
        .glassCard(padding: Theme.Spacing.m)
    }
}

/// The CTL / ATL / TSB tiles as one block. The dashboard's Fitness & Form section
/// and the Statistics PMC section show the same three numbers, so their names,
/// acronyms, colours, rounding and status wording live here — a column beside the
/// chart where there is room, a row above it on the phone.
struct PMCStatTiles: View {
    let result: PMCResult

    private var wide = WideLayout()

    var body: some View {
        if let s = result.snapshot {
            let ctlDelta = result.delta(daysAgo: 7) { $0.ctl }
            wide.tiles {
                tile("Fitness", "CTL", Theme.Palette.fitness, s.ctl, fitnessStatus(delta: ctlDelta)) { $0.ctl }
                tile("Fatigue", "ATL", Theme.Palette.fatigue, s.atl, s.atl > s.ctl ? "High load" : "Moderate load") { $0.atl }
                tile("Form", "TSB", Theme.Palette.form, s.tsb, formStatus(tsb: s.tsb)) { $0.tsb }
            }
            .frame(width: wide.tileColumnWidth)
            .frame(maxHeight: wide.rowHeight)
        }
    }

    /// Both screens show the same weekly change, so the tiles look it up themselves.
    private func tile(_ title: String, _ caption: String, _ dot: Color,
                      _ value: Double, _ status: String,
                      _ metric: (PMCPoint) -> Double) -> some View {
        PMCStatCard(title: title, caption: caption, dot: dot,
                    value: Int(value.rounded()),
                    delta: result.delta(daysAgo: 7, metric), status: status)
    }

    private func fitnessStatus(delta: Int) -> String {
        if delta > 1 { return "Productive build" }
        if delta < -1 { return "Declining" }
        return "Maintaining"
    }

    private func formStatus(tsb: Double) -> String {
        switch tsb {
        case ..<(-30):  return "Overreaching"
        case ..<(-10):  return "Optimal training"
        case ..<5:      return "Grey zone"
        case ..<20:     return "Fresh"
        default:        return "Very fresh"
        }
    }
}
