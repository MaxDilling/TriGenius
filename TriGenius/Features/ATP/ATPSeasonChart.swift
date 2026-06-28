import SwiftUI
import Charts

// MARK: - ATP season chart (Milestone 4)
//
// TrainingPeaks-style season view: completed TSS as filled weekly bars with the
// planned target drawn as a thin cap line above each (a cap, not a second bar, so
// the two never stack — stacked bars would sum past the axis when you out-train the
// plan). The three CTL curves (plan / actual / detraining) ride the right axis;
// Swift Charts has no native secondary axis, so — like the PMC chart — CTL is
// plotted in the TSS coordinate space and a trailing axis re-labels it. Hover
// (pointer) reveals the exact DAY's values incl. Form (TSB), planned vs actual.

extension ATPEventPriority {
    var tint: Color {
        switch self { case .a: Theme.Palette.danger; case .b: Theme.Palette.warning; case .c: .secondary }
    }
}

/// Everything the hover tooltip shows for one day.
private struct DayReadout: Equatable {
    let date: Date
    let period: String
    let weeksToEvent: Int?
    let plannedTSS: Double
    let completedTSS: Double
    let planCTL: Double?
    let actualCTL: Double?
    let planTSB: Double?
    let actualTSB: Double?
}

struct ATPSeasonChart: View {
    let plan: ATPPlan

    @State private var hoveredDate: Date?
    @State private var hoverX: CGFloat = 0

    private let cal = Calendar.current

    private var seasonStart: Date { plan.weeks.first?.weekStart ?? Date() }
    private var seasonEnd: Date { plan.planCurve.last?.date ?? seasonStart }

    /// Actual CTL clipped to the season window (history can reach back much further).
    private var actual: [PMCPoint] {
        plan.actualCurve.filter { $0.date >= seasonStart && $0.date <= seasonEnd }
    }

    private var completedBars: [(week: Date, tss: Double)] {
        plan.completedTSSByWeek
            .filter { $0.key >= seasonStart && $0.key <= seasonEnd && $0.value > 0 }
            .map { (week: $0.key, tss: $0.value) }
            .sorted { $0.week < $1.week }
    }

    // MARK: Dual-axis scaling

    private var tssMax: Double {
        let planned = plan.weeks.map(\.plannedTSS).max() ?? 0
        let done = completedBars.map(\.tss).max() ?? 0
        return max((max(planned, done) * 1.15 / 100).rounded(.up) * 100, 100)
    }
    private var ctlMax: Double {
        let m = (plan.planCurve + actual + plan.detrainingCurve).map(\.ctl).max() ?? 1
        return max((m * 1.15 / 10).rounded(.up) * 10, 10)
    }
    private func scaleCTL(_ ctl: Double) -> Double { ctl / ctlMax * tssMax }
    private var ctlTicks: [Double] {
        let step = max(10, (ctlMax / 5 / 10).rounded() * 10)
        return Array(stride(from: 0, through: ctlMax, by: step))
    }

    private func weekEnd(_ weekStart: Date) -> Date {
        cal.date(byAdding: .day, value: 6, to: weekStart) ?? weekStart
    }

    // MARK: Marks

    // Planned (grey) and completed (blue) as overlaid `RectangleMark`s — these
    // position each rect explicitly and do NOT auto-stack the way `BarMark` does, so
    // the two share one baseline instead of summing past the axis. Completed drawn
    // second → in front: the blue fills the grey plan from the bottom, and pokes
    // above it when the week was out-trained.
    @ChartContentBuilder private var barMarks: some ChartContent {
        ForEach(plan.weeks) { w in
            let r = barRange(w.weekStart)
            RectangleMark(xStart: .value("Start", r.0), xEnd: .value("End", r.1),
                          yStart: .value("Zero", 0), yEnd: .value("Planned TSS", w.plannedTSS))
                .foregroundStyle(.gray.opacity(0.28))
        }
        ForEach(completedBars, id: \.week) { b in
            let r = barRange(b.week)
            RectangleMark(xStart: .value("Start", r.0), xEnd: .value("End", r.1),
                          yStart: .value("Zero", 0), yEnd: .value("Completed TSS", b.tss))
                .foregroundStyle(Theme.Palette.info.opacity(0.85))
        }
    }

    /// X-range of a week's bar, centred with a ~30% gap to its neighbours.
    private func barRange(_ weekStart: Date) -> (Date, Date) {
        let week = 7.0 * 86400, gap = 7.0 * 86400 * 0.30
        return (weekStart.addingTimeInterval(gap / 2), weekStart.addingTimeInterval(week - gap / 2))
    }

    @ChartContentBuilder private var curveMarks: some ChartContent {
        ForEach(plan.planCurve) { p in
            LineMark(x: .value("Date", p.date), y: .value("CTL", scaleCTL(p.ctl)), series: .value("c", "plan"))
                .foregroundStyle(.blue)
        }
        ForEach(actual) { p in
            LineMark(x: .value("Date", p.date), y: .value("CTL", scaleCTL(p.ctl)), series: .value("c", "actual"))
                .foregroundStyle(Theme.Palette.success)
        }
        ForEach(plan.detrainingCurve) { p in
            LineMark(x: .value("Date", p.date), y: .value("CTL", scaleCTL(p.ctl)), series: .value("c", "detrain"))
                .foregroundStyle(.gray)
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }
    }

    @ChartContentBuilder private var eventMarks: some ChartContent {
        ForEach(plan.events, id: \.id) { e in
            RuleMark(x: .value("Event", e.date))
                .foregroundStyle(e.priority.tint.opacity(0.5))
                .annotation(position: .top, alignment: .center) {
                    Text(e.priority.rawValue).font(.caption2.bold()).foregroundStyle(e.priority.tint)
                }
        }
        if let d = hoveredDate {
            RuleMark(x: .value("Hover", d))
                .foregroundStyle(.secondary.opacity(0.45))
                .lineStyle(StrokeStyle(lineWidth: 1))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            Chart {
                barMarks
                curveMarks
                eventMarks
            }
            .chartYScale(domain: 0...tssMax)
            .chartYAxis {
                AxisMarks(position: .leading)
                AxisMarks(position: .trailing, values: ctlTicks.map(scaleCTL)) { value in
                    AxisTick()
                    AxisValueLabel {
                        if let scaled = value.as(Double.self) {
                            Text("\(Int((scaled / tssMax * ctlMax).rounded()))").foregroundStyle(.blue)
                        }
                    }
                }
            }
            .chartXAxis { AxisMarks(values: .stride(by: .month)) }
            .chartOverlay { proxy in hoverLayer(proxy) }
            .frame(height: 280)

            HStack(spacing: Theme.Spacing.l) {
                legend(.gray.opacity(0.6), "Planned TSS")
                legend(Theme.Palette.info, "Completed")
                legend(.blue, "Fitness ATP")
                legend(Theme.Palette.success, "Actual")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: Hover

    private func hoverLayer(_ proxy: ChartProxy) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let loc):
                            guard let frame = proxy.plotFrame else { return }
                            let x = loc.x - geo[frame].minX
                            guard let date = proxy.value(atX: x, as: Date.self) else { return }
                            let day = cal.startOfDay(for: date)
                            if day >= seasonStart && day <= seasonEnd { hoveredDate = day; hoverX = loc.x }
                        case .ended:
                            hoveredDate = nil
                        }
                    }
                if let d = hoveredDate {
                    let width: CGFloat = 210
                    tooltip(readout(on: d))
                        .frame(width: width)
                        .allowsHitTesting(false)   // pointer passes through → no flicker over the card
                        .position(x: min(max(hoverX, width / 2 + 4), geo.size.width - width / 2 - 4), y: 96)
                }
            }
        }
    }

    private func readout(on day: Date) -> DayReadout {
        let week = plan.weeks.first { day >= $0.weekStart && day <= weekEnd($0.weekStart) }
        let planPt = plan.planCurve.last { $0.date <= day }
        let isPast = day <= cal.startOfDay(for: Date())
        let actPt = isPast ? plan.actualCurve.last { $0.date <= day } : nil
        return DayReadout(
            date: day,
            period: week.map { "\($0.period.label) · Week \($0.periodWeekIndex)" } ?? ATPPeriod.transition.label,
            weeksToEvent: week?.weeksToNextEvent,
            plannedTSS: week?.plannedTSS ?? 0,
            completedTSS: week.map { plan.completedTSSByWeek[$0.weekStart] ?? 0 } ?? 0,
            planCTL: planPt?.ctl, actualCTL: actPt?.ctl,
            planTSB: planPt?.tsb, actualTSB: actPt?.tsb)
    }

    private func tooltip(_ r: DayReadout) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(r.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().year()))
                .font(.caption.bold())
            row("Period", r.period)
            if let w = r.weeksToEvent { row("Weeks to event", "\(w)") }
            row("ATP TSS", "\(Int(r.plannedTSS))")
            row("Completed", "\(Int(r.completedTSS))")
            row("Fitness ATP", fmt(r.planCTL), color: .blue)
            row("Fitness actual", fmt(r.actualCTL), color: Theme.Palette.success)
            row("Form ATP", fmt(r.planTSB))
            row("Form actual", fmt(r.actualTSB))
        }
        .padding(Theme.Spacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: .rect(cornerRadius: Theme.Radius.s, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous).strokeBorder(.separator))
    }

    private func row(_ label: String, _ value: String, color: Color = .primary) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).foregroundStyle(color).fontWeight(.medium)
        }
        .font(.caption)
    }

    private func fmt(_ v: Double?) -> String { v.map { String(Int($0.rounded())) } ?? "—" }

    private func legend(_ color: Color, _ label: String) -> some View {
        HStack(spacing: Theme.Spacing.xs) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label)
        }
    }
}
