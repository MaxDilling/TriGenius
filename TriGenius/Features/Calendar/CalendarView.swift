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

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)

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

                // The week-column layout already shows every day in full, so the
                // separate selected-day panel would just repeat it (desktop/iPad).
                if !(viewModel.mode == .week && useColumns) {
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
        HStack(spacing: 4) {
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
        LazyVGrid(columns: columns, spacing: 4) {
            ForEach(viewModel.gridDays, id: \.self) { day in
                DayCell(
                    day: day,
                    planned: viewModel.planned(on: day),
                    completed: viewModel.completed(on: day),
                    segments: viewModel.segments(on: day),
                    inMonth: viewModel.isInVisibleMonth(day),
                    isSelected: Calendar.current.isDate(day, inSameDayAs: viewModel.selectedDay),
                    isToday: Calendar.current.isDateInToday(day)
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

        return VStack(alignment: .leading, spacing: 10) {
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
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.primary.opacity(0.05)))
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

    private var isPast: Bool { day < Calendar.current.startOfDay(for: Date()) }

    var body: some View {
        VStack(spacing: 3) {
            Text("\(Calendar.current.component(.day, from: day))")
                .font(.caption2.weight(isToday ? .bold : .regular))
                .foregroundStyle(isToday ? Color.accentColor : (inMonth ? .primary : .secondary))

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

            Spacer(minLength: 0)

            // Future/today: availability at a glance. (Completed days read from
            // the solid sport chips above — no separate checkmark.)
            if !isPast && !segments.isEmpty {
                SegmentBar(states: segments, style: .pips)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 60, alignment: .top)
        .padding(.vertical, 4)
        .padding(.horizontal, 2)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.primary.opacity(inMonth ? 0.04 : 0.0))
        )
        .opacity(inMonth ? 1 : 0.5)
        .contentShape(Rectangle())
    }

    private func sportChip(sport: String, completed: Bool) -> some View {
        let family = SportFamily(sportKey: sport)
        return Image(systemName: family.icon)
            .font(.system(size: 9))
            .foregroundStyle(completed ? Color.white : family.color)
            // Fixed height so every chip is the same size — the swim glyph is
            // flatter than bike/run and would otherwise make a shorter capsule.
            .frame(maxWidth: .infinity, minHeight: 14, maxHeight: 14)
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
        HStack(spacing: 10) {
            Image(systemName: family.icon)
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Circle().fill(family.color))
            VStack(alignment: .leading, spacing: 2) {
                Text(activity.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(summary).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
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
        HStack(spacing: 10) {
            Image(systemName: family.icon)
                .foregroundStyle(family.color)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(workout.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(summaryLine).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if conflict {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
            Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
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
        HStack(spacing: 10) {
            Image(systemName: "calendar")
                .foregroundStyle(.secondary)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(window.title).font(.subheadline).lineLimit(1)
                Text(timeRange).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.03)))
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
