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
    /// Clear a week's pin (tap its orange bar). Nil ⇒ read-only chart.
    var onUnpinWeek: ((Date) -> Void)?
    /// Bleed the plot this far past its trailing edge so the chart reaches the card's
    /// right edge (cancels the enclosing card padding). 0 ⇒ no bleed.
    var edgeBleed: CGFloat = 0

    // Pointer location (chart-frame coords) driving the hover tooltip; pointer-only.
    @State private var hoverLoc: CGPoint?
    // Live leading-edge date of the visible (scrolled) window — lets overlays clamp to
    // the on-screen domain in date space, the only way to keep them inside the plot when
    // scrolling (the proxy reports full-content pixel coords, not the visible viewport).
    @State private var scrollX = Calendar.current.date(byAdding: .day, value: -14, to: Date()) ?? Date()
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
    }

    private var rampWarningCount: Int { plan.weeks.filter(\.rampExceeded).count }

    /// Center date of a week's bar (matches `barRange`), for positioning marks/labels.
    private func weekMid(_ weekStart: Date) -> Date {
        let r = barRange(weekStart)
        return Date(timeIntervalSince1970: (r.0.timeIntervalSince1970 + r.1.timeIntervalSince1970) / 2)
    }

    /// Visible (scrolled) date window — the whole season when it all fits. Overlays clamp
    /// to this in date space so a placed mark can only land inside the plot.
    private func visibleWindow(in width: CGFloat) -> (start: Date, end: Date) {
        let visible = visibleWeeks(in: width)
        guard visible < plan.weeks.count else { return (seasonStart, xDomainEnd) }
        return (scrollX, scrollX.addingTimeInterval(Double(visible) * 7 * 86400))
    }

    // Weeks ramping faster than the athlete's max — a red triangle just above the bar top.
    // An overlay (a mark annotation doesn't render here); each triangle is clamped in date
    // space to the visible window so it stays inside the plot instead of bleeding into the
    // pinned axes when scrolling.
    private func rampWarningLayer(_ proxy: ChartProxy) -> some View {
        GeometryReader { geo in
            if let frame = proxy.plotFrame {
                let f = geo[frame]
                let win = visibleWindow(in: geo.size.width)
                ZStack(alignment: .topLeading) {
                    ForEach(plan.weeks.filter(\.rampExceeded)) { w in
                        let mid = weekMid(w.weekStart)
                        if mid >= win.start, mid <= win.end,
                           let x = proxy.position(forX: mid),
                           let y = proxy.position(forY: w.plannedTSS) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 8)).foregroundStyle(Theme.Palette.danger)
                                .position(x: f.minX + x, y: f.minY + y - 7)
                        }
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                .clipped()
                .allowsHitTesting(false)
            }
        }
    }

    /// Minimum px per week below which the bars read as squeezed → switch to scrolling.
    private let minWeekWidth: CGFloat = 26

    /// Weeks that fit at a readable density in `width`; full season when it all fits.
    private func visibleWeeks(in width: CGFloat) -> Int {
        let total = max(plan.weeks.count, 1)
        guard width > 0 else { return total }
        return min(max(1, Int(width / minWeekWidth)), total)
    }

    /// End of the X span — the later of the last week's end and the last curve point.
    private var xDomainEnd: Date {
        max(seasonEnd, plan.weeks.last.map { weekEnd($0.weekStart) } ?? seasonEnd)
    }

    /// Initial scroll lands ~2 weeks before today so the current state is in view.
    private var scrollAnchor: Date {
        let anchor = cal.date(byAdding: .day, value: -14, to: cal.startOfDay(for: Date())) ?? seasonStart
        return min(max(anchor, seasonStart), seasonEnd)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            GeometryReader { geo in
                let visible = visibleWeeks(in: geo.size.width)
                let scrollable = visible < plan.weeks.count
                Chart {
                    periodBandMarks
                    barMarks
                    if showForm { formMarks }
                    curveMarks
                    eventMarks
                }
                .chartYScale(domain: bandBottom...tssMax)
                // Pin the X span to the season so Charts adds no trailing padding (which
                // otherwise leaves dead width on the right).
                .chartXScale(domain: seasonStart...xDomainEnd)
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
                // Scroll horizontally (axes stay pinned) only when the weeks don't fit.
                .chartScrollableAxes(scrollable ? .horizontal : [])
                .chartXVisibleDomain(length: Double(visible) * 7 * 86400)
                .chartScrollPosition(x: $scrollX)
                .onAppear { scrollX = scrollAnchor }
                // Pin/unpin live on the plot itself (not a covering overlay) so they
                // arbitrate with the chart's scroll: a tap removes a pin, a long-press
                // then drag sets one, and a plain swipe falls through to scrolling.
                .chartGesture { proxy in ExclusiveGesture(unpinTap(proxy), pinDrag(proxy)) }
                // The tooltip is pointer-driven; hover sits on the chart itself — not a
                // covering overlay — so it never intercepts the pin/unpin gestures below.
                // (A hit-testable overlay above `chartGesture` swallowed every click.)
                .onContinuousHover { phase in
                    if case .active(let loc) = phase { hoverLoc = loc } else { hoverLoc = nil }
                }
                .chartOverlay { proxy in periodLabelLayer(proxy) }
                .chartOverlay { proxy in rampWarningLayer(proxy) }
                .chartOverlay { proxy in hoverDrawLayer(proxy) }
            }
            .frame(height: 280)
            // Bleed the plot to the card's right edge (cancels the card's trailing padding).
            .padding(.trailing, -edgeBleed)

            HStack(spacing: Theme.Spacing.l) {
                legend(.gray.opacity(0.6), "Planned TSS")
                legend(Theme.Palette.info, "Completed TSS")
                legend(.blue, "ATP Fitness")
                legend(Theme.Palette.success, "Actual Fitness")
                Button { showForm.toggle() } label: {
                    HStack(spacing: Theme.Spacing.xs) {
                        Circle().fill(showForm ? formColor : .secondary.opacity(0.3)).frame(width: 7, height: 7)
                        Text("Form").foregroundStyle(showForm ? .secondary : .tertiary)
                    }
                }
                .buttonStyle(.plain)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            if rampWarningCount > 0 {
                Label("\(rampWarningCount) week\(rampWarningCount == 1 ? "" : "s") ramp faster than your max — fitness is climbing aggressively.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2).foregroundStyle(Theme.Palette.danger)
            }

            if onPinWeek != nil {
                Text("Press and hold a bar, then drag up or down to pin its TSS. Tap a pinned bar to remove.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    /// Period names centred on their band blocks; scales down / drops out when a
    /// block is too narrow to read (the color still carries the period; hover has it).
    /// Each block is clamped in *date* space to the visible window before it's placed,
    /// so its label always maps inside the plot and never bleeds into the pinned axes
    /// when scrolling (where the proxy reports full-content, not viewport, pixels).
    private func periodLabelLayer(_ proxy: ChartProxy) -> some View {
        GeometryReader { geo in
            if let frame = proxy.plotFrame {
                let f = geo[frame]
                let win = visibleWindow(in: geo.size.width)
                ZStack(alignment: .topLeading) {
                    ForEach(periodSegments, id: \.start) { seg in
                        let cs = max(seg.start, win.start), ce = min(seg.end, win.end)
                        if ce > cs,
                           let x0 = proxy.position(forX: cs),
                           let x1 = proxy.position(forX: ce),
                           let y = proxy.position(forY: (bandTop + bandBottom) / 2) {
                            // Centre in the on-screen slice of the block so a partly
                            // scrolled block keeps its label visible.
                            let gx0 = f.minX + x0, gx1 = f.minX + x1
                            if gx1 - gx0 > 12 {
                                Text(seg.period.label)
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .lineLimit(1).minimumScaleFactor(0.6)
                                    .frame(width: gx1 - gx0 - 2)
                                    .position(x: (gx0 + gx1) / 2, y: f.minY + y)
                            }
                        }
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                .clipped()
                .allowsHitTesting(false)
            }
        }
    }

    // MARK: Hover

    // Pure draw layer (never hit-tested, so it can't block the chart's gestures): the
    // pointer tooltip + its hover rule, plus the live value readout while dragging a pin.
    private func hoverDrawLayer(_ proxy: ChartProxy) -> some View {
        GeometryReader { geo in
            if let frame = proxy.plotFrame {
                let f = geo[frame]
                ZStack(alignment: .topLeading) {
                    if let wk = dragWeek,
                       let x = proxy.position(forX: weekMid(wk)),
                       let y = proxy.position(forY: dragTSS) {
                        Text("\(Int(dragTSS))")
                            .font(.caption2.bold()).foregroundStyle(Theme.Palette.warning)
                            .position(x: f.minX + x, y: f.minY + y - 9)
                    }
                    if let loc = hoverLoc, let day = hoverDay(at: loc.x - f.minX, proxy: proxy) {
                        Rectangle().fill(.secondary.opacity(0.45))
                            .frame(width: 1, height: f.height)
                            .position(x: loc.x, y: f.midY)
                        let width: CGFloat = 210, gap: CGFloat = 16
                        // Sit to the right of the cursor while it fits, else flip left.
                        let fitsRight = loc.x + gap + width <= geo.size.width
                        let centerX = fitsRight ? loc.x + gap + width / 2 : loc.x - gap - width / 2
                        tooltip(readout(on: day)).frame(width: width).position(x: centerX, y: 96)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                .allowsHitTesting(false)
            }
        }
    }

    /// The day under a plot-local x; nil off-season so the tooltip clears past the plot.
    private func hoverDay(at plotX: CGFloat, proxy: ChartProxy) -> Date? {
        guard let date = proxy.value(atX: plotX, as: Date.self) else { return nil }
        let day = cal.startOfDay(for: date)
        return (day >= seasonStart && day <= seasonEnd) ? day : nil
    }

    // Pin gesture, `chartGesture` hands plot-local points. On iOS the drag is gated
    // behind a long press so a plain horizontal swipe scrolls instead; on macOS a
    // mouse drag never competes with (trackpad) scroll, so a plain drag pins directly.
    private func pinDrag(_ proxy: ChartProxy) -> some Gesture {
        #if os(macOS)
        return DragGesture(minimumDistance: 2)
            .onChanged { updateDrag(startX: $0.startLocation.x, locY: $0.location.y, proxy: proxy) }
            .onEnded { _ in commitDrag() }
        #else
        return LongPressGesture(minimumDuration: 0.3)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .onChanged { value in
                guard case .second(true, let drag?) = value else { return }
                updateDrag(startX: drag.startLocation.x, locY: drag.location.y, proxy: proxy)
            }
            .onEnded { _ in commitDrag() }
        #endif
    }

    /// Begin/continue a pin drag: latch the week from the start x, track TSS from y (5-step).
    private func updateDrag(startX: CGFloat, locY: CGFloat, proxy: ChartProxy) {
        guard onPinWeek != nil else { return }
        if dragWeek == nil {
            guard let date = proxy.value(atX: startX, as: Date.self),
                  let wk = plan.weeks.first(where: { date >= $0.weekStart && date <= weekEnd($0.weekStart) })
            else { return }
            dragWeek = wk.weekStart
        }
        if let tss = proxy.value(atY: locY, as: Double.self) {
            dragTSS = (min(max(tss, 0), tssMax) / 5).rounded() * 5
        }
    }

    private func commitDrag() {
        if let wk = dragWeek { onPinWeek?(wk, dragTSS) }
        dragWeek = nil
    }

    /// Tap a pinned week's orange bar to clear its pin and hand the week back to the engine.
    private func unpinTap(_ proxy: ChartProxy) -> some Gesture {
        SpatialTapGesture()
            .onEnded { value in
                guard onUnpinWeek != nil,
                      let date = proxy.value(atX: value.location.x, as: Date.self),
                      let wk = plan.weeks.first(where: { date >= $0.weekStart && date <= weekEnd($0.weekStart) }),
                      wk.pinned
                else { return }
                onUnpinWeek?(wk.weekStart)
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
