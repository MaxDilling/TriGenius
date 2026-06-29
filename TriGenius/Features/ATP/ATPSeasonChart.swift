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

extension ATPPeriod {
    /// Band color, base→race ramping blue→warm (TP's period palette); transition grey.
    var tint: Color {
        switch self {
        case .base1: Color(red: 0.56, green: 0.71, blue: 0.85)
        case .base2: Color(red: 0.27, green: 0.47, blue: 0.71)
        case .base3: Color(red: 0.16, green: 0.31, blue: 0.55)
        case .build1: Color(red: 0.30, green: 0.62, blue: 0.55)
        case .build2: Color(red: 0.36, green: 0.61, blue: 0.36)
        case .peak: Color(red: 0.91, green: 0.62, blue: 0.25)
        case .race: Theme.Palette.danger
        case .transition: Color.gray
        }
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
    /// Commit a manual weekly-TSS pin (drag a bar up/down). Nil ⇒ read-only chart.
    var onPinWeek: ((Date, Double) -> Void)?

    @State private var hoveredDate: Date?
    @State private var hoverX: CGFloat = 0
    // Live drag preview: the dragged week's Monday + its in-flight TSS (committed on release).
    @State private var dragWeek: Date?
    @State private var dragTSS: Double = 0
    @State private var showForm = true

    private let cal = Calendar.current
    /// Form (TSB) amber — orange/gold, as in TrainingPeaks.
    private let formColor = Color(red: 0.93, green: 0.69, blue: 0.13)

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
    private var tssTicks: [Double] {
        let step = max(100, (tssMax / 5 / 100).rounded() * 100)
        return Array(stride(from: 0, through: tssMax, by: step))
    }

    // MARK: Form (TSB) — its own virtual scale, centred so TSB = 0 sits at the
    // vertical middle of the plot and the curve swings symmetrically up/down (TSB is
    // signed, so the shared CTL scale would clip the negatives below the baseline).

    /// Largest |TSB| across both curves (floored so a near-flat curve isn't blown up).
    private var tsbAbsMax: Double {
        max(20, (plan.planCurve + actual).map { abs($0.tsb) }.max() ?? 20)
    }
    private var formCenter: Double { tssMax * 0.5 }
    private func scaleTSB(_ tsb: Double) -> Double { formCenter + tsb / tsbAbsMax * tssMax * 0.42 }

    // MARK: Period band — a thin lane below the zero baseline (negative y-space), so
    // the colored blocks align to the bars without overlapping any data.

    private var bandTop: Double { -tssMax * 0.02 }
    private var bandBottom: Double { -tssMax * 0.10 }

    /// Contiguous runs of equal period (recovery weeks share their block's period; a
    /// period can recur across multiple events, so group by adjacency, not value).
    private var periodSegments: [(period: ATPPeriod, start: Date, end: Date)] {
        var segs: [(ATPPeriod, Date, Date)] = []
        for w in plan.weeks {
            if let last = segs.last, last.0 == w.period {
                segs[segs.count - 1].2 = weekEnd(w.weekStart)
            } else {
                segs.append((w.period, w.weekStart, weekEnd(w.weekStart)))
            }
        }
        return segs.map { (period: $0.0, start: $0.1, end: $0.2) }
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
        // Pinned weeks: an orange cap at the planned top so manual overrides read at a glance.
        ForEach(plan.weeks.filter { $0.pinned && $0.weekStart != dragWeek }) { w in
            let r = barRange(w.weekStart)
            RectangleMark(xStart: .value("Start", r.0), xEnd: .value("End", r.1),
                          yStart: .value("Cap bottom", max(w.plannedTSS - tssMax * 0.012, 0)),
                          yEnd: .value("Pinned TSS", w.plannedTSS))
                .foregroundStyle(Theme.Palette.warning)
        }
        // Live drag preview of the bar being pinned (value label is in the overlay so
        // it stays on top of the curves/area when dragging up).
        if let wk = dragWeek {
            let r = barRange(wk)
            RectangleMark(xStart: .value("Start", r.0), xEnd: .value("End", r.1),
                          yStart: .value("Zero", 0), yEnd: .value("Drag TSS", dragTSS))
                .foregroundStyle(Theme.Palette.warning.opacity(0.55))
        }
    }

    /// X-range of a week's bar, centred with a ~30% gap to its neighbours.
    private func barRange(_ weekStart: Date) -> (Date, Date) {
        let week = 7.0 * 86400, gap = 7.0 * 86400 * 0.30
        return (weekStart.addingTimeInterval(gap / 2), weekStart.addingTimeInterval(week - gap / 2))
    }

    @ChartContentBuilder private var periodBandMarks: some ChartContent {
        ForEach(periodSegments, id: \.start) { seg in
            RectangleMark(xStart: .value("Start", seg.start), xEnd: .value("End", seg.end),
                          yStart: .value("Band bottom", bandBottom), yEnd: .value("Band top", bandTop))
                .foregroundStyle(seg.period.tint)
        }
    }

    // Form (TSB): an amber area + dashed line for the ATP plan, a solid line for the
    // actual — on its own centred scale, filled from the (middle) zero line.
    @ChartContentBuilder private var formMarks: some ChartContent {
        RuleMark(y: .value("Form zero", formCenter))
            .foregroundStyle(formColor.opacity(0.25))
            .lineStyle(StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
        ForEach(plan.planCurve) { p in
            AreaMark(x: .value("Date", p.date),
                     yStart: .value("Form zero", formCenter), yEnd: .value("Form", scaleTSB(p.tsb)))
                .foregroundStyle(formColor.opacity(0.15))
        }
        ForEach(plan.planCurve) { p in
            LineMark(x: .value("Date", p.date), y: .value("Form", scaleTSB(p.tsb)), series: .value("c", "formPlan"))
                .foregroundStyle(formColor)
                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
        }
        ForEach(actual) { p in
            LineMark(x: .value("Date", p.date), y: .value("Form", scaleTSB(p.tsb)), series: .value("c", "formActual"))
                .foregroundStyle(formColor)
        }
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

    // Weeks ramping faster than the athlete's max — a red warning over the bar top.
    // Drawn last so its annotation stays above the curves/area.
    @ChartContentBuilder private var rampWarningMarks: some ChartContent {
        ForEach(plan.weeks.filter(\.rampExceeded)) { w in
            let r = barRange(w.weekStart)
            let mid = Date(timeIntervalSince1970: (r.0.timeIntervalSince1970 + r.1.timeIntervalSince1970) / 2)
            PointMark(x: .value("Week", mid), y: .value("TSS", w.plannedTSS))
                .symbolSize(0)
                .annotation(position: .top, spacing: 1) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 8)).foregroundStyle(Theme.Palette.danger)
                }
        }
    }

    private var rampWarningCount: Int { plan.weeks.filter(\.rampExceeded).count }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            Chart {
                periodBandMarks
                barMarks
                if showForm { formMarks }
                curveMarks
                eventMarks
                rampWarningMarks
            }
            .chartYScale(domain: bandBottom...tssMax)
            .chartYAxis {
                AxisMarks(position: .leading, values: tssTicks)
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
            .chartOverlay { proxy in periodLabelLayer(proxy) }
            .chartOverlay { proxy in hoverLayer(proxy) }
            .frame(height: 280)

            HStack(spacing: Theme.Spacing.l) {
                legend(.gray.opacity(0.6), "Planned TSS")
                legend(Theme.Palette.info, "Completed")
                legend(.blue, "Fitness ATP")
                legend(Theme.Palette.success, "Actual")
                Button { showForm.toggle() } label: {
                    HStack(spacing: Theme.Spacing.xs) {
                        Circle().fill(showForm ? formColor : .secondary.opacity(0.3)).frame(width: 7, height: 7)
                        Text("Form").foregroundStyle(showForm ? .secondary : .tertiary)
                    }
                }
                .buttonStyle(.plain)
                if onPinWeek != nil { legend(Theme.Palette.warning, "Pinned") }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            if rampWarningCount > 0 {
                Label("\(rampWarningCount) week\(rampWarningCount == 1 ? "" : "s") ramp faster than your max — fitness is climbing aggressively.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2).foregroundStyle(Theme.Palette.danger)
            }

            if onPinWeek != nil {
                Text("Drag a bar up or down to pin that week's TSS.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    /// Period names centred on their band blocks; scales down / drops out when a
    /// block is too narrow to read (the color still carries the period; hover has it).
    private func periodLabelLayer(_ proxy: ChartProxy) -> some View {
        GeometryReader { geo in
            if let frame = proxy.plotFrame {
                let f = geo[frame]
                ForEach(periodSegments, id: \.start) { seg in
                    if let x0 = proxy.position(forX: seg.start),
                       let x1 = proxy.position(forX: seg.end),
                       let y = proxy.position(forY: (bandTop + bandBottom) / 2) {
                        Text(seg.period.label)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1).minimumScaleFactor(0.6)
                            .frame(width: max(x1 - x0 - 2, 0))
                            .position(x: f.minX + (x0 + x1) / 2, y: f.minY + y)
                            .allowsHitTesting(false)
                    }
                }
            }
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
                    .gesture(pinDrag(proxy, geo))
                if let wk = dragWeek, let frame = proxy.plotFrame {
                    let r = barRange(wk)
                    let mid = Date(timeIntervalSince1970: (r.0.timeIntervalSince1970 + r.1.timeIntervalSince1970) / 2)
                    if let x = proxy.position(forX: mid), let y = proxy.position(forY: dragTSS) {
                        let f = geo[frame]
                        Text("\(Int(dragTSS))")
                            .font(.caption2.bold()).foregroundStyle(Theme.Palette.warning)
                            .position(x: f.minX + x, y: f.minY + y - 9)
                            .allowsHitTesting(false)
                    }
                }
                if let d = hoveredDate {
                    let width: CGFloat = 210
                    let gap: CGFloat = 16
                    // Sit to the right of the cursor while it fits, else flip to the left.
                    let fitsRight = hoverX + gap + width <= geo.size.width
                    let centerX = fitsRight ? hoverX + gap + width / 2 : hoverX - gap - width / 2
                    tooltip(readout(on: d))
                        .frame(width: width)
                        .allowsHitTesting(false)   // pointer passes through → no flicker over the card
                        .position(x: centerX, y: 96)
                }
            }
        }
    }

    /// Drag a week's bar up/down to pin its TSS; commits on release. No-op read-only.
    private func pinDrag(_ proxy: ChartProxy, _ geo: GeometryProxy) -> some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                guard onPinWeek != nil, let frame = proxy.plotFrame else { return }
                let plot = geo[frame]
                if dragWeek == nil {
                    let x = value.startLocation.x - plot.minX
                    guard let date = proxy.value(atX: x, as: Date.self),
                          let wk = plan.weeks.first(where: { date >= $0.weekStart && date <= weekEnd($0.weekStart) })
                    else { return }
                    dragWeek = wk.weekStart
                }
                if let tss = proxy.value(atY: value.location.y - plot.minY, as: Double.self) {
                    dragTSS = (min(max(tss, 0), tssMax) / 5).rounded() * 5
                }
            }
            .onEnded { _ in
                if let wk = dragWeek { onPinWeek?(wk, dragTSS) }
                dragWeek = nil
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
