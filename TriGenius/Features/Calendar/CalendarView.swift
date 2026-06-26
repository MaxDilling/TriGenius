import SwiftUI

/// Shared layout constants for the calendar (so the month grid's week-number gutter
/// and the nav bar's weekday header line up).
enum CalendarLayout {
    static let monthGutter: CGFloat = 30
}

// MARK: - Training Calendar
//
// FEATURES.md "Training calendar screen" + "Extended calendar — past workouts and
// daily life context": Week and Month views of scheduled + completed workouts and the
// athlete's real-world commitments (EventKit), mirroring Apple Calendar. The month is
// a horizontally paged grid (system events as the three color-coded availability bars
// under each day); the week is a continuously-scrollable hour-grid (`WeekTimeGridView`).
// Tap a day to drill into the week, tap an event for its detail, and drag a planned
// workout onto another day to reschedule it — updating the local store and Garmin.

/// A tapped calendar item, presented via programmatic navigation. Programmatic nav
/// (rather than wrapping each chip in a `NavigationLink`) keeps the chips' `.draggable`
/// working for drag-to-reschedule — a `NavigationLink` would swallow the drag gesture.
enum CalendarDetailItem: Identifiable, Hashable {
    case planned(ScheduledWorkoutRecord)
    case completed(ActivityRecord)
    case event(BusyWindow)

    var id: String {
        switch self {
        case .planned(let w): return "p-\(w.id)"
        case .completed(let a): return "c-\(a.id)"
        case .event(let e): return "e-\(e.id)"
        }
    }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct CalendarView: View {
    let dataSource: DataSource

    @State private var viewModel: CalendarViewModel
    @State private var detail: CalendarDetailItem?

    init(dataSource: DataSource) {
        self.dataSource = dataSource
        _viewModel = State(initialValue: CalendarViewModel(dataSource: dataSource))
    }

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var hSize
    private var visibleCount: Int { hSize == .regular ? 7 : 3 }
    private var useColumns: Bool { hSize == .regular }
    #else
    private var visibleCount: Int { 7 }
    private var useColumns: Bool { true }
    #endif

    var body: some View {
        VStack(spacing: Theme.Spacing.s) {
            CalendarNavBar(viewModel: viewModel, visibleCount: visibleCount)
                .padding(.horizontal)
                .padding(.top, Theme.Spacing.s)

            if viewModel.needsCalendarAccess {
                calendarAccessPrompt.padding(.horizontal)
            }

            content
                .frame(maxHeight: .infinity)
        }
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .navigationDestination(item: $detail) { item in
            switch item {
            case .planned(let workout): PlannedWorkoutDetailView(workout: workout)
            case .completed(let activity): TrainingDetailView(record: activity)
            case .event(let window): BusyEventDetailView(window: window)
            }
        }
        .onAppear { viewModel.load() }
        .onReceive(NotificationCenter.default.publisher(for: .trainingDataDidChange)) { _ in
            viewModel.load()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.mode {
        case .month:
            MonthScrollView(viewModel: viewModel, useColumns: useColumns,
                            onOpen: { detail = $0 })
        case .week:
            WeekTimeGridView(viewModel: viewModel, visibleCount: visibleCount,
                             onOpen: { detail = $0 })
        }
    }

    // MARK: Chrome

    private var calendarAccessPrompt: some View {
        Button {
            Task { await viewModel.requestCalendarAccess() }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "calendar.badge.plus")
                Text("Connect your calendar to see free training time")
                    .font(.subheadline)
                Spacer()
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.accentColor.opacity(0.12)))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Month pager (horizontally paged month grids)

/// The month view: a continuous vertical scroll of week rows (Apple-style), with a
/// week-number gutter on the left and the nav-bar header tracking the visible month.
private struct MonthScrollView: View {
    @Bindable var viewModel: CalendarViewModel
    let useColumns: Bool
    let onOpen: (CalendarDetailItem) -> Void

    @State private var scrollPosition = ScrollPosition()
    @State private var didInitialScroll = false
    // Geometry-driven month tracking is gated until the initial (or programmatic)
    // scroll has settled — otherwise the `y = 0` read fired before we scroll to the
    // focus week slides the loaded data window to the far-past first week, so the
    // events around "today" appear only once you scroll back into range.
    @State private var ready = false
    private let rowHeight: CGFloat = 104

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 0) {
                ForEach(viewModel.monthScrollWeeks, id: \.self) { weekStart in
                    WeekRow(viewModel: viewModel, weekStart: weekStart,
                            useColumns: useColumns, rowHeight: rowHeight, onOpen: onOpen)
                        .id(weekStart)
                }
            }
            .scrollTargetLayout()
        }
        .scrollPosition($scrollPosition)
        .scrollIndicators(.hidden)
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, y in
            guard ready else { return }
            let weeks = viewModel.monthScrollWeeks
            guard !weeks.isEmpty else { return }
            let index = max(0, min(weeks.count - 1, Int((y / rowHeight).rounded(.down))))
            viewModel.updateMonthScroll(topWeekStart: weeks[index])
        }
        .onAppear {
            guard !didInitialScroll else { return }
            didInitialScroll = true
            // Defer so the lazy rows realise their layout before we scroll to the
            // focus week (otherwise it no-ops and we start at the first backing week).
            DispatchQueue.main.async {
                scrollPosition.scrollTo(id: viewModel.monthFocusWeek)
                DispatchQueue.main.async { ready = true }
            }
        }
        .onChange(of: viewModel.monthScrollTick) { _, _ in
            ready = false
            scrollPosition.scrollTo(id: viewModel.monthFocusWeek)
            DispatchQueue.main.async { ready = true }
        }
    }
}

/// One week row in the continuous month grid: a week-number gutter + seven day cells.
private struct WeekRow: View {
    @Bindable var viewModel: CalendarViewModel
    let weekStart: Date
    let useColumns: Bool
    let rowHeight: CGFloat
    let onOpen: (CalendarDetailItem) -> Void

    private let gridLine = Color.primary.opacity(0.12)

    var body: some View {
        HStack(spacing: 0) {
            Text("\(viewModel.weekNumber(for: weekStart))")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
                .frame(width: CalendarLayout.monthGutter, alignment: .center)
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.top, 4)

            ForEach(viewModel.weekDays(for: weekStart), id: \.self) { day in
                DayCell(
                    day: day,
                    planned: viewModel.planned(on: day),
                    completed: viewModel.completed(on: day),
                    segments: viewModel.segments(on: day),
                    isToday: Calendar.current.isDateInToday(day),
                    wide: useColumns,
                    onSelectDay: { viewModel.focusWeek(on: day) },
                    onOpen: onOpen
                )
                .frame(maxWidth: .infinity)
                .dropDestination(for: String.self) { ids, _ in
                    guard let id = ids.first else { return false }
                    viewModel.move(workoutID: id, to: day)
                    return true
                }
            }
        }
        .frame(height: rowHeight)
        .overlay(alignment: .top) { Rectangle().fill(gridLine).frame(height: 0.5) }
    }
}

// MARK: - Day Cell (month grid)

private struct DayCell: View {
    let day: Date
    let planned: [ScheduledWorkoutRecord]
    let completed: [ActivityRecord]
    let segments: [TimeOfDaySegment: SegmentState]
    let isToday: Bool
    /// On roomy layouts (iPad / macOS) events show as icon-left + title rows,
    /// like Apple Calendar; on a compact iPhone they collapse to small chips.
    let wide: Bool
    /// Tapping the day (number or empty space) drills into the week view.
    let onSelectDay: () -> Void
    /// Tapping an event chip opens its detail (via programmatic navigation).
    let onOpen: (CalendarDetailItem) -> Void

    private var isPast: Bool { day < Calendar.current.startOfDay(for: Date()) }
    private let gridLine = Color.primary.opacity(0.12)

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            dayNumber

            if wide {
                wideEvents
            } else {
                compactChips
            }

            Spacer(minLength: 0)

            // Availability at a glance — only when the calendar is linked (no
            // data means no green bar). Completed days read from the events above.
            if !isPast && !segments.isEmpty {
                SegmentBar(states: segments)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(wide ? 4 : 3)
        // Thin top + leading hairlines render the month as a continuous grid
        // (Apple Calendar style) rather than a set of floating cards.
        .overlay(alignment: .leading) { Rectangle().fill(gridLine).frame(width: 0.5) }
        .contentShape(Rectangle())
        // Tap empty space → week view. Chips capture their own taps (and stay
        // draggable, which a NavigationLink wrapper would otherwise block).
        .onTapGesture { onSelectDay() }
    }

    private var isFirstOfMonth: Bool { Calendar.current.component(.day, from: day) == 1 }

    private var dayNumber: some View {
        HStack(spacing: 3) {
            // At a month boundary, label the new month inline (Apple-style).
            if isFirstOfMonth {
                Text(day.formatted(.dateTime.month(.abbreviated)))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
            Text("\(Calendar.current.component(.day, from: day))")
                .font(.caption.weight(isToday ? .bold : .regular))
                .foregroundStyle(isToday ? .white : .primary)
                .frame(width: 22, height: 22)
                .background { if isToday { Circle().fill(Color.accentColor) } }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Wide layout — icon left, then workout title (Apple Calendar style)

    private var wideEvents: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(completed.prefix(3), id: \.id) { activity in
                eventRow(sport: activity.sport, title: activity.name, filled: true)
                    .contentShape(Rectangle())
                    .onTapGesture { onOpen(.completed(activity)) }
            }
            let plannedSlots = max(0, 3 - completed.count)
            ForEach(planned.prefix(plannedSlots)) { workout in
                eventRow(sport: workout.sport, title: workout.name, filled: false)
                    .contentShape(Rectangle())
                    .onTapGesture { onOpen(.planned(workout)) }
                    .draggable(workout.id)
            }
            let overflow = completed.count + planned.count - 3
            if overflow > 0 {
                Text("+\(overflow) more")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .padding(.leading, 2)
            }
        }
    }

    private func eventRow(sport: String, title: String, filled: Bool) -> some View {
        let family = SportFamily(sportKey: sport)
        return HStack(spacing: 4) {
            Image(systemName: family.icon)
                .font(.system(size: 9))
                .foregroundStyle(filled ? Color.white : family.color)
            Text(title)
                .font(.system(size: 11))
                .lineLimit(1)
                .foregroundStyle(filled ? Color.white : .primary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(family.color.opacity(filled ? 0.9 : 0.18), in: RoundedRectangle(cornerRadius: 4))
    }

    // MARK: Compact layout — small sport chips (narrow iPhone month grid)

    private var compactChips: some View {
        VStack(spacing: 2) {
            ForEach(completed.prefix(2), id: \.id) { activity in
                sportChip(sport: activity.sport, completed: true)
                    .contentShape(Rectangle())
                    .onTapGesture { onOpen(.completed(activity)) }
            }
            ForEach(planned.prefix(max(0, 2 - completed.count))) { workout in
                sportChip(sport: workout.sport, completed: false)
                    .contentShape(Rectangle())
                    .onTapGesture { onOpen(.planned(workout)) }
                    .draggable(workout.id)
            }
            let overflow = planned.count + completed.count - 2
            if overflow > 0 {
                Text("+\(overflow)")
                    .font(.system(size: 8)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func sportChip(sport: String, completed: Bool) -> some View {
        let family = SportFamily(sportKey: sport)
        return Image(systemName: family.icon)
            .font(.system(size: 9))
            .foregroundStyle(completed ? Color.white : family.color)
            // Fixed height so every chip is the same size — the swim glyph is
            // flatter than bike/run and would otherwise make a shorter capsule.
            .frame(maxWidth: .infinity, minHeight: 12, maxHeight: 12)
            .padding(.vertical, 2)
            .background(
                Group {
                    if completed {
                        Capsule().fill(family.color)
                    } else {
                        Capsule().stroke(family.color, lineWidth: 1)
                    }
                }
            )
    }
}

// MARK: - System calendar event detail (read-only)

/// A minimal read-only detail for a real-world calendar commitment, reached by
/// tapping an all-day event in the week grid. Workouts have their own rich details.
struct BusyEventDetailView: View {
    let window: BusyWindow

    var body: some View {
        List {
            Section {
                LabeledContent("Title", value: window.title)
                if window.isAllDay {
                    LabeledContent("When", value: window.start.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                    LabeledContent("All day", value: "Yes")
                } else {
                    LabeledContent("Starts", value: window.start.formatted(.dateTime.weekday().day().month().hour().minute()))
                    LabeledContent("Ends", value: window.end.formatted(.dateTime.hour().minute()))
                }
            } header: {
                Text("Calendar event")
            }
        }
        .navigationTitle(window.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

// MARK: - Segment availability bar

/// Renders the morning / midday / evening availability for a day as a compact
/// three-bar strip under each month cell (green = free, orange / red = busy).
struct SegmentBar: View {
    let states: [TimeOfDaySegment: SegmentState]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(TimeOfDaySegment.allCases) { segment in
                Capsule()
                    .fill((states[segment] ?? .free).color)
                    .frame(height: 3)
            }
        }
        .frame(maxWidth: .infinity)
    }
}
