import SwiftUI
import Charts

// MARK: - Summary tile
//
// The one summary card — PMC values, the ramp rate, every physiological marker, on
// the dashboard, in Statistics and in chat. A title row in the metric's colour with
// the reading's date and a chevron (every tile opens its detail), the value over its
// unit, and a full-bleed sparkline footer.

struct SummaryTile: View {
    struct Delta {
        let value: String
        let isRise: Bool
        let color: Color
    }

    let title: String
    let color: Color
    var date: Date?
    let value: String
    var unit = ""
    var delta: Delta?
    var status: String?
    /// The sparkline, already cut to the window the tile summarises.
    var series: [MetricPoint] = []
    /// A trend drawn over `series`, which then fades behind it.
    var trendLine: [MetricPoint]?

    /// Tiles flow into as many columns as fit; a fixed set of `fill` tiles spreads
    /// across the full width instead where there is room.
    static func columns(wide: Bool, fill: Int? = nil) -> [GridItem] {
        if wide, let fill {
            return Array(repeating: GridItem(.flexible(), spacing: Theme.Spacing.m), count: fill)
        }
        return [GridItem(.adaptive(minimum: wide ? 240 : 150), spacing: Theme.Spacing.m)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                CardHeader(title: title, color: color, date: date)
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xs) {
                    Text(value).font(.title.bold()).monospacedDigit()
                    Text(unit).font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    if let delta {
                        HStack(spacing: 1) {
                            Image(systemName: delta.isRise ? "arrow.up" : "arrow.down")
                            Text(delta.value)
                        }
                        .font(.caption2)
                        .foregroundStyle(delta.color)
                    }
                }
                if let status {
                    Text(status).font(.caption).foregroundStyle(color)
                }
            }
            .padding([.top, .horizontal], Theme.Spacing.l)
            sparkline.frame(height: 48)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(padding: 0)
        .clipShape(.rect(cornerRadius: Theme.Radius.l, style: .continuous))
    }

    @ViewBuilder
    private var sparkline: some View {
        if series.count >= 2 {
            Chart {
                ForEach(series) { p in
                    LineMark(x: .value("Date", p.date), y: .value("Value", p.value), series: .value("Series", "Readings"))
                        .foregroundStyle(color.opacity(trendLine == nil ? 1 : 0.35))
                    AreaMark(x: .value("Date", p.date), y: .value("Value", p.value))
                        .foregroundStyle(color.opacity(0.12))
                }
                ForEach(trendLine ?? []) { p in
                    LineMark(x: .value("Date", p.date), y: .value("Value", p.value), series: .value("Series", "Trend"))
                        .foregroundStyle(color)
                        .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            // Extra bottom buffer keeps the line floating above the card's lower
            // edge; the area still fills the gap beneath it.
            .chartYScale(domain: tightDomain(series, topPad: 0.15, bottomPad: 0.45))
            // Charts does not clip its plot to the frame — the area would bleed far
            // outside the small sparkline rect.
            .clipped()
        } else {
            // No trend to draw — keep the tile height with a quiet baseline.
            Rectangle()
                .fill(.secondary.opacity(0.12))
                .frame(height: 1)
                .frame(maxHeight: .infinity)
        }
    }
}

/// A card's title row: the name in its colour, the date of the reading, a chevron.
struct CardHeader: View {
    let title: String
    let color: Color
    var date: Date?
    /// Shown in the date's place — a live figure rather than a timestamp.
    var detail: Text?

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Text(title).font(.headline).foregroundStyle(color).lineLimit(1)
            Spacer(minLength: Theme.Spacing.xs)
            if let text = detail ?? date.map({ Text(Self.label($0)) }) {
                text.font(.caption).foregroundStyle(.secondary)
            }
            Chevron()
        }
    }

    private static func label(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }
}

/// A Y-axis domain tightened to the data's own min/max (plus a margin on each
/// side), so even small progressions fill the chart's height instead of
/// flattening against `.automatic`'s round-number padding.
func tightDomain(_ points: [MetricPoint], topPad: Double = 0.18, bottomPad: Double = 0.18) -> ClosedRange<Double> {
    let values = points.map(\.value)
    guard let lo = values.min(), let hi = values.max() else { return 0...1 }
    let range = hi - lo
    // A flat series has no range to scale by — fall back to a small synthetic span.
    let unit = range > 0 ? range : max(abs(hi) * 0.28, 1)
    return (lo - unit * bottomPad)...(hi + unit * topPad)
}

// MARK: - PMC tiles

/// The CTL / ATL / TSB tiles. The dashboard and Statistics show the same three
/// numbers, so their names, colours, rounding and status wording live here. The
/// tiles flatten into the caller's grid; `range` is the sparkline window.
struct PMCStatTiles<Destination: View>: View {
    let result: PMCResult
    let range: TimeRange
    @ViewBuilder let destination: () -> Destination

    var body: some View {
        if let s = result.snapshot {
            tile("Fitness (CTL)", Theme.Palette.fitness, s.ctl, fitnessStatus(delta: result.delta(daysAgo: 7) { $0.ctl })) { $0.ctl }
            tile("Fatigue (ATL)", Theme.Palette.fatigue, s.atl, s.atl > s.ctl ? "High load" : "Moderate load") { $0.atl }
            tile("Form (TSB)", Theme.Palette.form, s.tsb, formStatus(tsb: s.tsb)) { $0.tsb }
        }
    }

    private func tile(_ title: String, _ color: Color, _ value: Double, _ status: String,
                      _ metric: @escaping (PMCPoint) -> Double) -> some View {
        let delta = result.delta(daysAgo: 7, metric)
        return NavigationLink(destination: destination) {
            SummaryTile(title: title, color: color, value: "\(Int(value.rounded()))",
                        delta: delta == 0 ? nil : .init(value: "\(abs(delta))", isRise: delta > 0, color: color),
                        status: status,
                        series: result.points.filter { range.contains($0.date) }
                            .map { MetricPoint(date: $0.date, value: metric($0)) })
        }
        .buttonStyle(.plain)
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
