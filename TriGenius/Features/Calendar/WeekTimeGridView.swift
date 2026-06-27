import SwiftUI

// MARK: - Week time grid (Apple-Calendar-style multi-day view)
//
// FEATURES.md "Extended calendar": a continuously-scrollable multi-day time grid —
// hour rows × day columns, like Apple Calendar's week view. Workouts and all-day
// commitments live in the all-day band above the grid; timed calendar events are
// positioned inside the grid at their start/end. The hour grid is pinch-zoomable and
// the columns scroll horizontally and endlessly (3 visible on a compact iPhone, 7 on
// roomy devices). Drag a workout pill onto another day's all-day band to reschedule.

struct WeekTimeGridView: View {
    @Bindable var viewModel: CalendarViewModel
    /// Day columns visible at once (3 compact / 7 roomy).
    let visibleCount: Int
    /// Opens a tapped workout / event detail (via programmatic navigation).
    let onOpen: (CalendarDetailItem) -> Void

    // Vertical scale of the hour grid (pinch to zoom), clamped to a sane band.
    @State private var hourHeight: CGFloat = 44
    @State private var baseHourHeight: CGFloat = 44

    // One scroll surface for both axes (Apple-Calendar style): the day grid is the only
    // scrollable thing; the day header and hour gutter live *inside* the same scroll and are
    // pinned by countering the live `offset`, so they can never drift against the grid.
    //
    // The horizontal position is tracked by *day identity*, not pixels: `leftmostDay` is the
    // id of the leading day column, written by the system as you scroll and — crucially —
    // preserved by SwiftUI across a layout change (rotation / resize). That makes rotation a
    // non-event (the same day stays put) and means the header can never desync, because it is
    // derived from the actual leading column rather than a separately-stored guess.
    @State private var leftmostDay: Date?
    @State private var offset = CGPoint.zero
    @State private var didInitialScroll = false
    // Vertical component of the scroll-position anchor. A horizontal jump (Today / a
    // date-strip tap) re-anchors the focus day in *both* axes, so a fixed `.topLeading`
    // would yank the grid back to 00:00. Instead we steer the anchor's y to the
    // content-y we want to keep on screen (the current time when jumping, 07:00 on
    // launch). Because every day column spans the full height, the anchor's y never
    // changes *which* day is read as leftmost — identity tracking is untouched.
    @State private var verticalAnchor: CGFloat = 0
    // When expanded, the all-day band shows every workout/event (not just a few +N),
    // so days with many sessions stay reachable.
    @State private var allDayExpanded = false

    private let gutterWidth: CGFloat = 52
    private let hours = Array(0...24)
    private let gridLine = Color.primary.opacity(0.12)

    // All-day band sizing. The band is only as tall as the busiest *visible* column
    // needs (capped), so an empty week keeps a tight one-line header.
    private let dateLabelHeight: CGFloat = 28
    private let pillHeight: CGFloat = 30
    private let pillSpacing: CGFloat = 2
    private let maxAllDayRows = 3

    private func allDayCount(_ day: Date) -> Int {
        viewModel.planned(on: day).count + viewModel.completed(on: day).count
            + viewModel.allDayWindows(on: day).count
    }

    /// Rows the all-day band needs for the columns currently on screen (capped).
    private var visibleAllDayRows: Int {
        guard let start = viewModel.weekGridIndex(of: viewModel.firstVisibleDay) else { return 0 }
        let end = min(start + visibleCount, viewModel.weekGridDays.count)
        let busiest = viewModel.weekGridDays[start..<end].map(allDayCount).max() ?? 0
        return min(allDayExpanded ? 12 : maxAllDayRows, busiest)
    }

    private var bandHeight: CGFloat {
        guard visibleAllDayRows > 0 else { return 0 }
        return CGFloat(visibleAllDayRows) * pillHeight + CGFloat(visibleAllDayRows - 1) * pillSpacing
    }

    private var headerHeight: CGFloat {
        dateLabelHeight + (bandHeight > 0 ? bandHeight + 8 : 0) + 6
    }

    var body: some View {
        GeometryReader { geo in
            let columnWidth = max(72, (geo.size.width - gutterWidth) / CGFloat(visibleCount))
            let gridHeight = CGFloat(24) * hourHeight
            // Columns occupy exactly their own width; the leading gutter space is a scroll
            // *content margin* (below), not in-content padding — see the ScrollView note.
            let totalWidth = CGFloat(viewModel.weekGridDays.count) * columnWidth

            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    // Day columns — header *and* grid for a day live in ONE lazily-realised
                    // column, so they share a single horizontal layout and can never drift
                    // apart. The header is pinned to the top within its own column via the
                    // shared vertical offset; every column uses the same offset, so the
                    // header band stays a straight, aligned row.
                    LazyHStack(spacing: 0) {
                        ForEach(viewModel.weekGridDays, id: \.self) { day in
                            dayColumn(day: day, columnWidth: columnWidth, gridHeight: gridHeight)
                                .id(day)
                        }
                    }
                    .scrollTargetLayout()   // identifies the day columns for scrollPosition(id:)

                    // Hour gutter — pinned to the left edge (counters horizontal scroll),
                    // scrolls vertically with the grid.
                    hourGutter(height: gridHeight)
                        .frame(width: gutterWidth, height: gridHeight)
                        .padding(.top, headerHeight)
                        .background(Color.appBackground)
                        .offset(x: offset.x)

                    // Corner (week number + all-day toggle) — pinned to both edges.
                    cornerCell
                        .frame(width: gutterWidth, height: headerHeight, alignment: .topLeading)
                        .background(Color.appBackground)
                        .offset(x: offset.x, y: offset.y)
                }
                .frame(width: totalWidth, height: headerHeight + gridHeight, alignment: .topLeading)
                // Grow/shrink the all-day band smoothly when the busiest visible column gains or
                // loses a row (or on expand/collapse) instead of snapping — keyed to the row count
                // so ongoing scroll offsets are never animated. Matches Apple Calendar's behaviour.
                .animation(.easeInOut(duration: 0.22), value: visibleAllDayRows)
                // Lock each drag to one axis (vertical *or* horizontal, never diagonal) on the
                // underlying UIScrollView — SwiftUI exposes no modifier for this.
                .scrollAxisLock()
            }
            // The gutter's width is reserved as a leading *content margin*, not in-content
            // padding. Crucially, `scrollPosition(id:)` respects this inset: a day scrolled
            // to with `.topLeading` rests at the margin's inner edge (just right of the
            // pinned gutter) instead of sliding underneath it — so "Today" / a date-strip
            // tap can never land the focus day under the gutter. The rest position and the
            // programmatic landing now agree, so exactly `visibleCount` columns are on
            // screen and the all-day band sizes for the right set of days.
            .contentMargins(.leading, gutterWidth, for: .scrollContent)
            .scrollPosition(id: $leftmostDay, anchor: UnitPoint(x: 0, y: verticalAnchor))
            // The only thing read from pixels is the live `offset`, used purely to pin the
            // hour gutter / header / corner. The *day* is tracked by identity (`leftmostDay`),
            // never inferred from the offset — so a width change can't misread it.
            .onScrollGeometryChange(for: CGPoint.self) { $0.contentOffset } action: { _, o in
                offset = o
            }
            .gesture(
                MagnifyGesture()
                    .onChanged { value in
                        hourHeight = min(120, max(24, baseHourHeight * value.magnification))
                    }
                    .onEnded { _ in baseHourHeight = hourHeight }
            )
            .onAppear {
                guard !didInitialScroll else { return }
                didInitialScroll = true
                // Defer so the lazy stack has realised its layout before we position it.
                DispatchQueue.main.async {
                    // Open the week scrolled to 07:00 (just below the sticky header) rather
                    // than midnight.
                    verticalAnchor = anchorFraction(forContentY: 7 * hourHeight,
                                                    columnHeight: headerHeight + gridHeight,
                                                    viewport: geo.size.height)
                    leftmostDay = viewModel.weekFocusDay
                }
            }
            // Drive the header + loaded window from whatever day is actually leading. This is
            // the single source of truth, so the strip and grid stay in lock-step by design.
            .onChange(of: leftmostDay) { _, day in
                guard let day else { return }
                viewModel.firstVisibleDay = day
                viewModel.ensureWeekLoaded(around: day)
            }
            // "Today" / a date-strip tap: scroll by *id* (rotation-safe, no pixel math),
            // keeping the current time-of-day — anchor the jump at the live vertical offset
            // so the grid stays where it is and only the day changes.
            .onChange(of: viewModel.weekScrollTick) { _, _ in
                verticalAnchor = anchorFraction(forContentY: offset.y,
                                                columnHeight: headerHeight + gridHeight,
                                                viewport: geo.size.height)
                leftmostDay = viewModel.weekFocusDay
            }
        }
    }

    /// The anchor-y fraction that lands content-offset-y `y` at the top of the grid.
    /// `scrollPosition`'s anchor aligns the *same* unit point of the item and the
    /// viewport, so for a full-height column `contentOffset.y = fraction · (columnHeight
    /// − viewport)`. Inverting that gives the fraction for a desired offset (clamped, and
    /// 0 when the content is too short to scroll vertically).
    private func anchorFraction(forContentY y: CGFloat, columnHeight: CGFloat, viewport: CGFloat) -> CGFloat {
        let scrollable = columnHeight - viewport
        guard scrollable > 0 else { return 0 }
        return min(1, max(0, y / scrollable))
    }

    // MARK: One day column — grid + its own top-pinned header (single lazy item)

    private func dayColumn(day: Date, columnWidth: CGFloat, gridHeight: CGFloat) -> some View {
        ZStack(alignment: .top) {
            // Timed grid, pushed below the header band.
            DayColumnGrid(viewModel: viewModel, day: day, hourHeight: hourHeight,
                          columnWidth: columnWidth, onOpen: onOpen)
                .frame(width: columnWidth, height: gridHeight)
                .padding(.top, headerHeight)

            // Date label + all-day band, pinned to the top of the viewport. Opaque so the
            // grid scrolls *under* it; `zIndex` keeps it above its own column's grid.
            DayHeaderCell(
                viewModel: viewModel, day: day,
                rows: visibleAllDayRows, bandHeight: bandHeight,
                pillHeight: pillHeight, pillSpacing: pillSpacing,
                dateLabelHeight: dateLabelHeight, expanded: allDayExpanded,
                onOpen: onOpen, onExpand: { allDayExpanded = true }
            )
            .frame(width: columnWidth, height: headerHeight, alignment: .top)
            .background(Color.appBackground)
            .offset(y: offset.y)
            .zIndex(1)
        }
        .frame(width: columnWidth, height: headerHeight + gridHeight, alignment: .top)
    }

    // MARK: Corner (pinned both axes): week number + all-day collapse toggle

    private var cornerCell: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("W\(viewModel.weekNumber(for: viewModel.firstVisibleDay))")
                .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if bandHeight > 0 {
                // Tappable when expanded — collapses the all-day band back.
                Button { if allDayExpanded { allDayExpanded = false } } label: {
                    HStack(spacing: 2) {
                        Text("all-day").font(.system(size: 9)).foregroundStyle(.tertiary)
                        if allDayExpanded {
                            Image(systemName: "chevron.up").font(.system(size: 8)).foregroundStyle(.tertiary)
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(!allDayExpanded)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func hourGutter(height: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            Color.clear.frame(height: height)
            ForEach(hours, id: \.self) { hour in
                Text(String(format: "%02d:00", hour % 24))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 6)
                    .offset(y: CGFloat(hour) * hourHeight - 6)
            }
        }
    }

}

// MARK: - Day header cell (date label + all-day band)

/// One item in the all-day band: a workout (completed/planned), an all-day calendar
/// event, or an overflow marker when a day has more than the band can show.
private enum AllDayEntry: Identifiable {
    case completed(WorkoutRecord)
    case planned(WorkoutRecord)
    case event(BusyWindow)
    case overflow(Int)

    var id: String {
        switch self {
        case .completed(let a): return "c-\(a.id)"
        case .planned(let w): return "p-\(w.id)"
        case .event(let e): return "e-\(e.id)"
        case .overflow: return "overflow"
        }
    }
}

private struct DayHeaderCell: View {
    @Bindable var viewModel: CalendarViewModel
    let day: Date
    let rows: Int
    let bandHeight: CGFloat
    let pillHeight: CGFloat
    let pillSpacing: CGFloat
    let dateLabelHeight: CGFloat
    let expanded: Bool
    let onOpen: (CalendarDetailItem) -> Void
    let onExpand: () -> Void

    private var isToday: Bool { Calendar.current.isDateInToday(day) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(dateLabel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(isToday ? Color.accentColor : .primary)
                .lineLimit(1).minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, alignment: .center)
                .frame(height: dateLabelHeight)

            if bandHeight > 0 {
                allDayBand
            }
            Spacer(minLength: 0)
        }
        .overlay(alignment: .leading) { Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 0.5) }
    }

    // All-day band — workouts sit here (above the hour grid) together with any
    // all-day calendar commitments. Fixed height so every column lines up.
    private var allDayBand: some View {
        VStack(spacing: pillSpacing) {
            ForEach(entries) { entry in
                pill(for: entry).frame(height: pillHeight)
            }
        }
        .frame(height: bandHeight, alignment: .top)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 3)
        .contentShape(Rectangle())
        // Drag a workout pill here to reschedule it onto this day.
        .dropDestination(for: String.self) { ids, _ in
            guard let id = ids.first else { return false }
            viewModel.move(workoutID: id, to: day)
            return true
        }
    }

    @ViewBuilder
    private func pill(for entry: AllDayEntry) -> some View {
        switch entry {
        case .completed(let activity):
            // Workouts get a second metadata line (TSS + distance/time).
            AllDayPill(sport: activity.sport, title: activity.name,
                       subtitle: Self.completedMetadata(for: activity), kind: .completed)
                .contentShape(Rectangle())
                .onTapGesture { onOpen(.completed(activity)) }
        case .planned(let workout):
            AllDayPill(sport: workout.sport, title: workout.name,
                       subtitle: Self.plannedMetadata(for: workout), kind: .planned)
                .contentShape(Rectangle())
                .onTapGesture { onOpen(.planned(workout)) }
                .draggable(workout.id)
        case .event(let window):
            // System events stay single-line (no metadata).
            AllDayPill(sport: nil, title: window.title, subtitle: nil, kind: .event)
                .contentShape(Rectangle())
                .onTapGesture { onOpen(.event(window)) }
        case .overflow(let n):
            // Tap to expand the band so the hidden workouts become reachable.
            Button { onExpand() } label: {
                Text("+\(n) more")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    /// Compact "TSS + (distance or time)" line for a completed activity.
    private static func completedMetadata(for activity: WorkoutRecord) -> String? {
        var parts: [String] = []
        if let tss = activity.tss, tss > 0 { parts.append("\(Int(tss.rounded())) TSS") }
        if activity.distanceKm > 0 {
            parts.append(String(format: "%.1f km", activity.distanceKm))
        } else if activity.durationMinutes > 0 {
            parts.append(durationHM(activity.durationMinutes))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Compact "TSS target + duration" line for a planned workout.
    private static func plannedMetadata(for workout: WorkoutRecord) -> String? {
        var parts: [String] = []
        let family = SportFamily(sportKey: workout.sport)
        let tss = workout.targetTSS
            ?? WeeklyTargets.estimatedTSS(family: family, minutes: workout.targetDurationMinutes)
        if tss > 0 { parts.append("\(Int(tss.rounded())) TSS") }
        if workout.targetDurationMinutes > 0 { parts.append(durationHM(workout.targetDurationMinutes)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// All-day items capped to `rows`, with an overflow marker when there are more.
    private var entries: [AllDayEntry] {
        var all: [AllDayEntry] = viewModel.completed(on: day).map { .completed($0) }
            + viewModel.planned(on: day).map { .planned($0) }
            + viewModel.allDayWindows(on: day).map { .event($0) }
        guard rows > 0, all.count > rows else { return all }
        all = Array(all.prefix(rows - 1))
        let hidden = (viewModel.completed(on: day).count + viewModel.planned(on: day).count
            + viewModel.allDayWindows(on: day).count) - (rows - 1)
        all.append(.overflow(hidden))
        return all
    }

    private var dateLabel: String {
        let weekday = day.formatted(.dateTime.weekday(.abbreviated))
        let dayMonth = day.formatted(.dateTime.day().month(.abbreviated))
        return "\(weekday) – \(dayMonth)"
    }
}

// MARK: - Day column hour grid (timed events)

private struct DayColumnGrid: View {
    @Bindable var viewModel: CalendarViewModel
    let day: Date
    let hourHeight: CGFloat
    let columnWidth: CGFloat
    let onOpen: (CalendarDetailItem) -> Void

    private var isToday: Bool { Calendar.current.isDateInToday(day) }
    private let gridLine = Color.primary.opacity(0.10)

    var body: some View {
        let lanes = TimedEventLayout.lanes(for: timedItems)

        ZStack(alignment: .topLeading) {
            // Hourly gridlines + trailing day separator.
            ForEach(0...24, id: \.self) { hour in
                Rectangle().fill(gridLine)
                    .frame(height: 0.5)
                    .offset(y: CGFloat(hour) * hourHeight)
            }
            Rectangle().fill(gridLine).frame(width: 0.5)
                .frame(maxWidth: .infinity, alignment: .trailing)

            if isToday { nowIndicator }

            ForEach(lanes, id: \.item.id) { placed in
                let laneWidth = columnWidth / CGFloat(placed.laneCount)
                // Size the block to its lane + duration and place it with a single outer
                // `.offset`, so its tap target is exactly the visible block. (Wrapping it in a
                // full-height GeometryReader for the lane width — as before — made every block's
                // hit area span the whole column, so taps landed on the wrong / an empty slot.)
                TimedItemBlock(item: placed.item)
                    .frame(width: laneWidth, height: blockHeight(placed.item), alignment: .topLeading)
                    .contentShape(Rectangle())
                    .onTapGesture { onOpen(placed.item.detail) }
                    .offset(x: CGFloat(placed.lane) * laneWidth, y: yOffset(placed.item))
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// Timed calendar events, completed activities, and planned workouts that carry a
    /// start time. The grid copy is read-only — rescheduling stays in the all-day band.
    private var timedItems: [TimedItem] {
        let cal = Calendar.current
        let startOfDay = cal.startOfDay(for: day)
        var items: [TimedItem] = viewModel.busyWindows(on: day).map { window in
            TimedItem(id: "e-\(window.id)", start: window.start, end: window.end,
                      title: window.title, color: .secondary, detail: .event(window))
        }
        // Completed activities sit at their actual Garmin clock time (HealthKit ones
        // have no time, so they stay in the all-day band).
        for activity in viewModel.completed(on: day) {
            guard let minute = activity.startMinute,
                  let start = cal.date(byAdding: .minute, value: minute, to: startOfDay),
                  let end = cal.date(byAdding: .minute, value: max(1, Int(activity.durationMinutes)), to: start)
            else { continue }
            items.append(TimedItem(id: "c-\(activity.id)", start: start, end: end,
                                   title: activity.name,
                                   color: SportFamily(sportKey: activity.sport).color,
                                   detail: .completed(activity)))
        }
        for workout in viewModel.planned(on: day) {
            guard let minute = workout.startMinute,
                  let start = cal.date(byAdding: .minute, value: minute, to: startOfDay),
                  let end = cal.date(byAdding: .minute, value: max(1, Int(workout.targetDurationMinutes)), to: start)
            else { continue }
            items.append(TimedItem(id: "p-\(workout.id)", start: start, end: end,
                                   title: workout.name,
                                   color: SportFamily(sportKey: workout.sport).color,
                                   detail: .planned(workout)))
        }
        return items
    }

    private var nowIndicator: some View {
        let minute = Calendar.current.component(.hour, from: Date()) * 60
            + Calendar.current.component(.minute, from: Date())
        return Rectangle()
            .fill(Theme.Palette.danger)
            .frame(height: 1.5)
            .offset(y: CGFloat(minute) / 60 * hourHeight)
    }

    private func minutes(_ date: Date) -> Int {
        let start = Calendar.current.startOfDay(for: day)
        return min(24 * 60, max(0, Int(date.timeIntervalSince(start) / 60)))
    }

    private func yOffset(_ item: TimedItem) -> CGFloat {
        CGFloat(minutes(item.start)) / 60 * hourHeight
    }

    private func blockHeight(_ item: TimedItem) -> CGFloat {
        let span = max(0, minutes(item.end) - minutes(item.start))
        return max(16, CGFloat(span) / 60 * hourHeight)
    }
}

/// A timed entry in the hour grid — a calendar event (grey) or a workout (discipline
/// colour). Read-only; tapping opens its detail.
private struct TimedItem: Identifiable {
    let id: String
    let start: Date
    let end: Date
    let title: String
    let color: Color
    let detail: CalendarDetailItem
}

// MARK: - Event / workout pills

private struct TimedItemBlock: View {
    let item: TimedItem

    var body: some View {
        // Top-aligned (like Apple): the colour bar fills the height, the text hugs the
        // top so long blocks don't centre their label.
        HStack(alignment: .top, spacing: 4) {
            RoundedRectangle(cornerRadius: 1.5).fill(item.color)
                .frame(width: 3).frame(maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.system(size: 11, weight: .medium))
                    .lineLimit(2).foregroundStyle(.primary)
                Text(timeRange).font(.system(size: 9)).foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(item.color.opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
    }

    private var timeRange: String {
        let s = item.start.formatted(.dateTime.hour().minute())
        let e = item.end.formatted(.dateTime.hour().minute())
        return "\(s) – \(e)"
    }
}

/// A compact pill in the all-day band. Workouts are discipline-tinted (completed
/// filled, planned light) and carry a second metadata line; calendar events are muted
/// and single-line. Tap/drag is wired by the caller (so `.draggable` keeps working).
private struct AllDayPill: View {
    enum Kind { case completed, planned, event }
    let sport: String?
    let title: String
    /// Optional metadata line (workouts only) — TSS + distance/time.
    let subtitle: String?
    let kind: Kind

    private var family: SportFamily? { sport.map { SportFamily(sportKey: $0) } }

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            Image(systemName: family?.icon ?? "calendar")
                .font(.system(size: 9))
                .foregroundStyle(iconColor)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .foregroundStyle(textColor)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 9))
                        .lineLimit(1)
                        .foregroundStyle(subtitleColor)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, maxHeight: .infinity,
               alignment: subtitle == nil ? .leading : .topLeading)
        .background(background, in: RoundedRectangle(cornerRadius: 4))
    }

    private var subtitleColor: Color {
        kind == .completed ? Color.white.opacity(0.85) : .secondary
    }
    private var iconColor: Color {
        switch kind {
        case .completed: return .white
        case .planned: return family?.color ?? .accentColor
        case .event: return .secondary
        }
    }
    private var textColor: Color {
        kind == .completed ? .white : .primary
    }
    private var background: Color {
        switch kind {
        case .completed: return (family?.color ?? .accentColor).opacity(0.9)
        case .planned: return (family?.color ?? .accentColor).opacity(0.18)
        case .event: return Color.secondary.opacity(0.18)
        }
    }
}

// MARK: - Overlap layout

/// Packs overlapping timed events into side-by-side lanes. Within a cluster of
/// mutually-overlapping events every event reports the same `laneCount` so the column
/// width is split evenly (Apple-Calendar style).
private enum TimedEventLayout {
    struct Placed { let item: TimedItem; let lane: Int; let laneCount: Int }

    static func lanes(for items: [TimedItem]) -> [Placed] {
        let sorted = items.sorted { $0.start < $1.start }
        var result: [Placed] = []
        var cluster: [(item: TimedItem, lane: Int)] = []
        var clusterEnd: Date?

        func flush() {
            let count = max(1, (cluster.map { $0.lane }.max() ?? 0) + 1)
            for entry in cluster {
                result.append(Placed(item: entry.item, lane: entry.lane, laneCount: count))
            }
            cluster.removeAll()
            clusterEnd = nil
        }

        for item in sorted {
            if let end = clusterEnd, item.start >= end {
                flush()
            }
            // First lane whose current occupant has ended.
            var lane = 0
            let used = Set(cluster.filter { $0.item.end > item.start }.map { $0.lane })
            while used.contains(lane) { lane += 1 }
            cluster.append((item, lane))
            clusterEnd = max(clusterEnd ?? item.end, item.end)
        }
        flush()
        return result
    }
}

// MARK: - One-axis-at-a-time scroll lock

extension View {
    /// Constrains a two-axis `ScrollView` so each drag pans either vertically *or*
    /// horizontally — never diagonally — by enabling the underlying `UIScrollView`'s
    /// directional lock. SwiftUI has no native modifier for this. No-op on macOS, where
    /// trackpad scrolling already behaves.
    @ViewBuilder
    func scrollAxisLock() -> some View {
        #if os(iOS)
        background(DirectionalScrollLock())
        #else
        self
        #endif
    }
}

#if os(iOS)
import UIKit

/// Reaches the nearest ancestor `UIScrollView` once the SwiftUI content is in the
/// window and turns on `isDirectionalLockEnabled`, so a drag locks to the axis it
/// started on (the standard iOS "no diagonal scrolling" behaviour).
private struct DirectionalScrollLock: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView { Probe() }
    func updateUIView(_ uiView: UIView, context: Context) {}

    private final class Probe: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            var ancestor = superview
            while let view = ancestor {
                if let scroll = view as? UIScrollView {
                    scroll.isDirectionalLockEnabled = true
                    break
                }
                ancestor = view.superview
            }
        }
    }
}
#endif
