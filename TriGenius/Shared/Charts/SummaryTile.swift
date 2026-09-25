import SwiftUI

// MARK: - Summary tile
//
// The one summary card — PMC values, the ramp rate, every physiological marker, on
// the dashboard, in Statistics and in chat. A title row in the metric's colour with
// the reading's date and a chevron (every tile opens its detail), the value over its
// unit, and a full-bleed sparkline footer. Hovering the sparkline moves the readout
// to the point under the pointer; a tap still opens the detail.

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
    /// For a signed series (Form, ramp rate), whose sign is the reading: zero stays in
    /// view as a dotted line and the area fills toward it.
    var zeroLine = false
    /// A sparkline point as the readout shows it while the pointer hovers the line.
    let display: (MetricPoint) -> String

    @State private var hoverDate: Date?

    private var hovered: MetricPoint? {
        hoverDate.flatMap { date in series.first { $0.date == date } }
    }

    /// Tiles flow into as many columns as fit; a fixed set of `fill` tiles spreads
    /// across the full width instead where there is room. The compact minimum is the
    /// narrowest tile whose title ("Fitness (CTL)") doesn't truncate — still two
    /// columns on the smallest iPhone.
    static func columns(wide: Bool, fill: Int? = nil) -> [GridItem] {
        if wide, let fill {
            return Array(repeating: GridItem(.flexible(), spacing: Theme.Spacing.m), count: fill)
        }
        return [GridItem(.adaptive(minimum: wide ? 240 : 165), spacing: Theme.Spacing.m)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                CardHeader(title: title, color: color, date: hovered?.date ?? date)
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xs) {
                    Text(hovered.map(display) ?? value).font(.title.bold()).monospacedDigit()
                    Text(unit).font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    if let delta {
                        HStack(spacing: 1) {
                            Image(systemName: delta.isRise ? "arrow.up" : "arrow.down")
                            Text(delta.value)
                        }
                        .font(.caption2)
                        .foregroundStyle(delta.color)
                        // The delta is today's; it steps aside while an older reading shows.
                        .opacity(hovered == nil ? 1 : 0)
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

    /// Plain paths, not a `Chart`: a screen of tiles re-lays out every mark of every
    /// Chart on each frame of a window resize, where a path only re-strokes.
    @ViewBuilder
    private var sparkline: some View {
        if series.count >= 2, let first = series.first?.date, let last = series.last?.date, last > first {
            // Extra bottom buffer keeps the line floating above the card's lower
            // edge; the area still fills the gap beneath it.
            let domain = tightDomain(series + (zeroLine ? [MetricPoint(date: first, value: 0)] : []),
                                     topPad: 0.15, bottomPad: 0.45)
            let span = last.timeIntervalSince(first)
            let unitY = { (value: Double) in (value - domain.lowerBound) / (domain.upperBound - domain.lowerBound) }
            let unit = { (p: MetricPoint) in CGPoint(x: p.date.timeIntervalSince(first) / span, y: unitY(p.value)) }
            let readings = series.map(unit)
            let zero = zeroLine ? unitY(0) : nil
            ZStack {
                SparkPath(points: readings, fillTo: zero ?? 0).fill(color.opacity(0.12))
                if let zero {
                    SparkPath(points: [CGPoint(x: 0, y: zero), CGPoint(x: 1, y: zero)])
                        .stroke(color.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                }
                SparkPath(points: readings)
                    .stroke(color.opacity(trendLine == nil ? 1 : 0.35), style: StrokeStyle(lineWidth: 2, lineJoin: .round))
                if let trendLine {
                    SparkPath(points: trendLine.map(unit))
                        .stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                }
                if let hovered {
                    let at = unit(hovered)
                    SparkPath(points: [CGPoint(x: at.x, y: 0), CGPoint(x: at.x, y: 1)])
                        .stroke(.secondary.opacity(0.6), lineWidth: 1)
                    SparkDot(at: at).fill(color)
                }
            }
            .horizontalScrubbing(Binding(
                get: { hoverDate.map { $0.timeIntervalSince(first) / span } },
                set: { fraction in
                    let date = fraction.flatMap { fraction in
                        let target = first.addingTimeInterval(fraction * span)
                        return series.min { abs($0.date.timeIntervalSince(target)) < abs($1.date.timeIntervalSince(target)) }?.date
                    }
                    if date != hoverDate { hoverDate = date }
                }
            ), touch: false)
        } else {
            // No trend to draw — keep the tile height with a quiet baseline.
            Rectangle()
                .fill(.secondary.opacity(0.12))
                .frame(height: 1)
                .frame(maxHeight: .infinity)
        }
    }
}

/// A sparkline through points in unit space (0…1 each way, y up); `fillTo` closes it
/// to that height as an area.
private nonisolated struct SparkPath: Shape {
    let points: [CGPoint]
    var fillTo: CGFloat?

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard let first = points.first, let last = points.last else { return path }
        path.addLines(points.map(rect.point))
        if let fillTo {
            path.addLine(to: rect.point(CGPoint(x: last.x, y: fillTo)))
            path.addLine(to: rect.point(CGPoint(x: first.x, y: fillTo)))
            path.closeSubpath()
        }
        return path
    }
}

/// The hovered reading's dot, at a unit-space point.
private nonisolated struct SparkDot: Shape {
    let at: CGPoint

    func path(in rect: CGRect) -> Path {
        let center = rect.point(at)
        return Path(ellipseIn: CGRect(x: center.x - 3, y: center.y - 3, width: 6, height: 6))
    }
}

nonisolated private extension CGRect {
    /// A unit-space point (y up) in this rect.
    func point(_ unit: CGPoint) -> CGPoint {
        CGPoint(x: minX + unit.x * width, y: maxY - unit.y * height)
    }
}

/// A card's title row: the name in its colour, the date of the reading, a chevron.
struct CardHeader: View {
    let title: String
    let color: Color
    var date: Date?

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Text(title).font(.headline).foregroundStyle(color).lineLimit(1)
            Spacer(minLength: Theme.Spacing.xs)
            if let date {
                Text(Self.label(date)).font(.caption).foregroundStyle(.secondary)
            }
            Chevron()
        }
        .padding(.top, -Theme.Spacing.titleTuck)
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

/// The CTL / ATL / TSB + ramp-rate tiles. The dashboard and Statistics show the same
/// four numbers, so their names, colours, rounding and status wording live here. The
/// tiles flatten into the caller's grid; `range` is the sparkline window and the
/// one the Fitness & Form detail opens at.
struct PMCStatTiles: View {
    let result: PMCResult
    let range: TimeRange

    var body: some View {
        if let s = result.snapshot {
            tile("Fitness (CTL)", Theme.Palette.fitness, s.ctl, fitnessStatus(delta: result.delta(daysAgo: 7) { $0.ctl })) { $0.ctl }
            tile("Fatigue (ATL)", Theme.Palette.fatigue, s.atl, s.atl > s.ctl ? "High load" : "Moderate load") { $0.atl }
            tile("Form (TSB)", Theme.Palette.form, s.tsb, formStatus(tsb: s.tsb), zeroLine: true) { $0.tsb }
            let ramp = RampRate.weeklySeries(points: result.points, weeks: range.weeks(first: result.points.first?.date))
            if let week = ramp.last {
                rampTile(week, series: ramp)
            }
        }
    }

    private func rampTile(_ week: RampWeek, series: [RampWeek]) -> some View {
        let band = RampRate.safeBand
        let format: (Double) -> String = { $0.formatted(.number.precision(.fractionLength(1)).sign(strategy: .always())) }
        return NavigationLink { PMCDetailView(result: result, range: range) } label: {
            SummaryTile(title: "Ramp rate", color: Theme.Palette.info,
                        value: format(week.delta),
                        unit: "CTL/wk",
                        status: band.contains(week.delta) ? "Sustainable build"
                            : week.delta > band.upperBound ? "Above the safe ramp" : "Below build range",
                        series: series.map { MetricPoint(date: $0.weekStart, value: $0.delta) },
                        zeroLine: true) { format($0.value) }
        }
        .buttonStyle(.plain)
    }

    private func tile(_ title: String, _ color: Color, _ value: Double, _ status: String,
                      zeroLine: Bool = false, _ metric: @escaping (PMCPoint) -> Double) -> some View {
        let delta = result.delta(daysAgo: 7, metric)
        return NavigationLink { PMCDetailView(result: result, range: range) } label: {
            SummaryTile(title: title, color: color, value: "\(Int(value.rounded()))",
                        delta: delta == 0 ? nil : .init(value: "\(abs(delta))", isRise: delta > 0, color: color),
                        status: status,
                        series: result.points.filter { range.contains($0.date) }
                            .map { MetricPoint(date: $0.date, value: metric($0)) },
                        zeroLine: zeroLine) { "\(Int($0.value.rounded()))" }
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
