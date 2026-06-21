import SwiftUI

// MARK: - Training Calendar
//
// FEATURES.md "Training calendar screen" + "Extended calendar — past workouts and
// daily life context": Week and Month views of scheduled + completed workouts and
// the athlete's real-world commitments (EventKit), with a per-day time-of-day
// availability indicator (morning / midday / evening free?) so it's obvious where
// there is still time to train. Drag a planned-workout chip onto another day to
// reschedule it (or onto a week-view segment to also set its time of day); updates
// the local store and Garmin.

struct CalendarView: View {
    let dataSource: DataSource

    @State private var viewModel: CalendarViewModel

    init(dataSource: DataSource) {
        self.dataSource = dataSource
        _viewModel = State(initialValue: CalendarViewModel(dataSource: dataSource))
    }

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var hSize
    private var useColumns: Bool { hSize == .regular }
    #else
    private var useColumns: Bool { true }   // macOS / visionOS: always roomy
    #endif

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                modePicker
                header

                if viewModel.needsCalendarAccess {
                    calendarAccessPrompt
                }

                switch viewModel.mode {
                case .month:
                    weekdayHeader
                    monthGrid
                case .week:
                    WeekView(viewModel: viewModel, useColumns: useColumns)
                }

                // The week view already shows every day in full (stacked on
                // compact, side-by-side on roomy devices), so the separate
                // selected-day panel only adds value in month mode.
                if viewModel.mode == .month {
                    selectedDayDetail
                }
            }
            .padding()
        }
        .navigationTitle("Calendar")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Today") { viewModel.goToToday() }
            }
        }
        .onAppear { viewModel.load() }
        .onReceive(NotificationCenter.default.publisher(for: .scheduledWorkoutsDidChange)) { _ in
            viewModel.load()
        }
    }

    // MARK: Header

    private var modePicker: some View {
        Picker("View", selection: $viewModel.mode) {
            ForEach(CalendarMode.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
    }

    private var header: some View {
        HStack {
            Button { viewModel.showPrevious() } label: {
                Image(systemName: "chevron.left")
            }
            Spacer()
            Text(viewModel.title).font(.headline)
            Spacer()
            Button { viewModel.showNext() } label: {
                Image(systemName: "chevron.right")
            }
        }
        .buttonStyle(.plain)
        .font(.title3)
    }

    private var weekdayHeader: some View {
        HStack(spacing: 0) {
            ForEach(viewModel.weekdaySymbols, id: \.self) { symbol in
                Text(symbol)
                    .font(.caption2).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

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

    // MARK: Month grid

    private var monthGrid: some View {
        LazyVGrid(columns: columns, spacing: 0) {
            ForEach(viewModel.gridDays, id: \.self) { day in
                DayCell(
                    day: day,
                    planned: viewModel.planned(on: day),
                    completed: viewModel.completed(on: day),
                    segments: viewModel.segments(on: day),
                    inMonth: viewModel.isInVisibleMonth(day),
                    isSelected: Calendar.current.isDate(day, inSameDayAs: viewModel.selectedDay),
                    isToday: Calendar.current.isDateInToday(day),
                    wide: useColumns
                )
                .onTapGesture { viewModel.selectedDay = Calendar.current.startOfDay(for: day) }
                .dropDestination(for: String.self) { ids, _ in
                    guard let id = ids.first else { return false }
                    viewModel.move(workoutID: id, to: day)
                    return true
                }
            }
        }
    }

    // MARK: Selected-day detail

    private var selectedDayDetail: some View {
        let day = viewModel.selectedDay
        let planned = viewModel.planned(on: day)
        let completed = viewModel.completed(on: day)
        let busy = viewModel.busyWindows(on: day)

        return VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            HStack {
                Text(day.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                    .font(.headline)
                Spacer()
                let load = viewModel.selectedWeekLoad()
                if load.minutes > 0 {
                    Text("Week: \(durationHM(load.minutes)) • \(Int(load.tss.rounded())) TSS")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if !viewModel.segments(on: day).isEmpty {
                SegmentBar(states: viewModel.segments(on: day), style: .labeled)
            }

            if completed.isEmpty && planned.isEmpty && busy.isEmpty {
                Text("Nothing here yet. Drag a workout onto this day, or ask the coach to schedule one.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }

            ForEach(completed) { activity in
                CompletedRow(activity: activity)
            }
            ForEach(planned) { workout in
                PlannedRow(workout: workout, conflict: viewModel.conflict(for: workout),
                           segment: viewModel.assignedSegment(workout))
                    .draggable(workout.id)
            }
            if !busy.isEmpty {
                ForEach(busy) { window in
                    BusyRow(window: window)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(cornerRadius: Theme.Radius.l)
    }
}

// MARK: - Day Cell (month grid)

private struct DayCell: View {
    let day: Date
    let planned: [ScheduledWorkoutRecord]
    let completed: [ActivityRecord]
    let segments: [TimeOfDaySegment: SegmentState]
    let inMonth: Bool
    let isSelected: Bool
    let isToday: Bool
    /// On roomy layouts (iPad / macOS) events show as icon-left + title rows,
    /// like Apple Calendar; on a compact iPhone they collapse to small chips.
    let wide: Bool

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
                SegmentBar(states: segments, style: .pips)
            }
        }
        .frame(maxWidth: .infinity, minHeight: wide ? 96 : 62, alignment: .topLeading)
        .padding(wide ? 4 : 3)
        .background(isSelected ? Color.accentColor.opacity(0.12) : .clear)
        // Thin top + leading hairlines render the month as a continuous grid
        // (Apple Calendar style) rather than a set of floating cards.
        .overlay(alignment: .top) { Rectangle().fill(gridLine).frame(height: 0.5) }
        .overlay(alignment: .leading) { Rectangle().fill(gridLine).frame(width: 0.5) }
        .opacity(inMonth ? 1 : 0.45)
        .contentShape(Rectangle())
    }

    private var dayNumber: some View {
        Text("\(Calendar.current.component(.day, from: day))")
            .font(.caption.weight(isToday ? .bold : .regular))
            .foregroundStyle(isToday ? .white : (inMonth ? .primary : .secondary))
            .frame(width: 22, height: 22)
            .background { if isToday { Circle().fill(Color.accentColor) } }
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Wide layout — icon left, then workout title (Apple Calendar style)

    private var wideEvents: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(completed.prefix(3), id: \.id) { activity in
                eventRow(sport: activity.sport, title: activity.name, filled: true)
            }
            let plannedSlots = max(0, 3 - completed.count)
            ForEach(planned.prefix(plannedSlots)) { workout in
                eventRow(sport: workout.sport, title: workout.name, filled: false)
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
            }
            ForEach(planned.prefix(max(0, 2 - completed.count))) { workout in
                sportChip(sport: workout.sport, completed: false)
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

// MARK: - Shared rows (used by detail panel + week view)

/// A completed activity, shown solid/checked.
struct CompletedRow: View {
    let activity: ActivityRecord
    private var family: SportFamily { SportFamily(sportKey: activity.sport) }

    var body: some View {
        NavigationLink {
            TrainingDetailView(record: activity)
        } label: {
            card
        }
        .buttonStyle(.plain)
    }

    private var card: some View {
        HStack(spacing: Theme.Spacing.s) {
            Image(systemName: family.icon)
                .font(.caption).foregroundStyle(family.color)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(activity.name).font(.subheadline.weight(.medium)).lineLimit(1)
                Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: Theme.Spacing.xs)
            Image(systemName: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(Theme.Palette.success)
        }
        .padding(.vertical, Theme.Spacing.xs)
        .padding(.horizontal, Theme.Spacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Discipline tint marks this as a training session (vs. flat life events).
        .background(family.color.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.Radius.s))
    }

    private var summary: String {
        var parts: [String] = []
        if activity.durationMinutes > 0 { parts.append(durationHM(activity.durationMinutes)) }
        if activity.distanceKm > 0 { parts.append(String(format: "%.1f km", activity.distanceKm)) }
        if let tss = activity.tss, tss > 0 { parts.append("\(Int(tss.rounded())) TSS") }
        return parts.isEmpty ? "Completed" : parts.joined(separator: "  •  ")
    }
}

/// A planned workout, draggable. Shows a warning when its segment isn't free.
struct PlannedRow: View {
    let workout: ScheduledWorkoutRecord
    var conflict: Bool = false
    var segment: TimeOfDaySegment? = nil

    private var family: SportFamily { SportFamily(sportKey: workout.sport) }
    private var targetTSS: Double {
        workout.targetTSS ?? WeeklyTargets.estimatedTSS(family: family, minutes: workout.targetDurationMinutes)
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.s) {
            Image(systemName: family.icon)
                .font(.caption).foregroundStyle(family.color)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(workout.name).font(.subheadline.weight(.medium)).lineLimit(1)
                Text(summaryLine).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: Theme.Spacing.xs)
            if conflict {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(Theme.Palette.warning)
            }
            Image(systemName: "line.3.horizontal")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.vertical, Theme.Spacing.xs)
        .padding(.horizontal, Theme.Spacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Planned training: same discipline tint as completed, lighter, so the
        // day's training stands out from flat life events.
        .background(family.color.opacity(0.10), in: RoundedRectangle(cornerRadius: Theme.Radius.s))
    }

    private var summaryLine: String {
        var parts: [String] = []
        if let segment { parts.append(segment.label) }
        if workout.targetDurationMinutes > 0 { parts.append(durationHM(workout.targetDurationMinutes)) }
        if targetTSS > 0 { parts.append("\(Int(targetTSS.rounded())) TSS target") }
        return parts.isEmpty ? "Target not set" : parts.joined(separator: "  •  ")
    }
}

/// A real-world calendar commitment, muted.
struct BusyRow: View {
    let window: BusyWindow

    var body: some View {
        // Life events are visually subordinate: colorless, flat, minimal height,
        // so the colored training rows stay the day's anchors.
        HStack(spacing: Theme.Spacing.s) {
            Image(systemName: "calendar")
                .font(.caption2).foregroundStyle(.secondary)
                .frame(width: 18)
            Text(window.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: Theme.Spacing.xs)
            Text(timeRange).font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, Theme.Spacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var timeRange: String {
        let start = window.start.formatted(.dateTime.hour().minute())
        let end = window.end.formatted(.dateTime.hour().minute())
        return "\(start) – \(end)"
    }
}

// MARK: - Segment availability bar

/// Renders the morning / midday / evening availability for a day. `.pips` is a
/// compact 3-bar strip (month cells); `.labeled` shows AM/Mid/PM tinted pills.
struct SegmentBar: View {
    let states: [TimeOfDaySegment: SegmentState]
    var style: Style = .pips

    enum Style { case pips, labeled }

    var body: some View {
        switch style {
        case .pips:
            HStack(spacing: 2) {
                ForEach(TimeOfDaySegment.allCases) { segment in
                    Capsule()
                        .fill((states[segment] ?? .free).color)
                        .frame(height: 3)
                }
            }
            .frame(maxWidth: .infinity)
        case .labeled:
            HStack(spacing: 6) {
                ForEach(TimeOfDaySegment.allCases) { segment in
                    let state = states[segment] ?? .free
                    HStack(spacing: 4) {
                        Image(systemName: segment.icon).font(.system(size: 9))
                        Text(segment.shortLabel).font(.caption2.weight(.semibold))
                    }
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(state.color)
                    .background(Capsule().fill(state.color.opacity(0.15)))
                }
            }
        }
    }
}
