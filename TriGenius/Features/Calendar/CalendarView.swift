import SwiftUI

// MARK: - Training Calendar
//
// FEATURES.md "Training calendar screen" + "Drag-and-drop workout reschedule":
// a month view of scheduled + completed workouts. Drag a planned-workout chip
// onto another day to reschedule it (updates the local store and Garmin).

struct CalendarView: View {
    let dataSource: DataSource

    @State private var viewModel: CalendarViewModel

    init(dataSource: DataSource) {
        self.dataSource = dataSource
        _viewModel = State(initialValue: CalendarViewModel(dataSource: dataSource))
    }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                monthHeader
                weekdayHeader
                monthGrid
                selectedDayDetail
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
    }

    // MARK: Header

    private var monthHeader: some View {
        HStack {
            Button { viewModel.showPreviousMonth() } label: {
                Image(systemName: "chevron.left")
            }
            Spacer()
            Text(viewModel.monthTitle).font(.headline)
            Spacer()
            Button { viewModel.showNextMonth() } label: {
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

    // MARK: Grid

    private var monthGrid: some View {
        LazyVGrid(columns: columns, spacing: 4) {
            ForEach(viewModel.gridDays, id: \.self) { day in
                DayCell(
                    day: day,
                    planned: viewModel.planned(on: day),
                    hasCompleted: viewModel.hasCompleted(on: day),
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
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(viewModel.selectedDay.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                    .font(.headline)
                Spacer()
                let load = viewModel.selectedWeekLoad()
                if load.minutes > 0 {
                    Text("Week: \(durationHM(load.minutes)) • \(Int(load.tss.rounded())) TSS")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            let planned = viewModel.planned(on: viewModel.selectedDay)
            if planned.isEmpty {
                Text("No workouts planned. Drag a workout here, or ask the coach to schedule one.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                ForEach(planned) { workout in
                    PlannedRow(workout: workout)
                        .draggable(workout.id)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.primary.opacity(0.05)))
    }
}

// MARK: - Day Cell

private struct DayCell: View {
    let day: Date
    let planned: [ScheduledWorkoutRecord]
    let hasCompleted: Bool
    let inMonth: Bool
    let isSelected: Bool
    let isToday: Bool

    var body: some View {
        VStack(spacing: 3) {
            Text("\(Calendar.current.component(.day, from: day))")
                .font(.caption2.weight(isToday ? .bold : .regular))
                .foregroundStyle(isToday ? Color.accentColor : (inMonth ? .primary : .secondary))

            VStack(spacing: 2) {
                ForEach(planned.prefix(2)) { workout in
                    chip(for: workout)
                }
                if planned.count > 2 {
                    Text("+\(planned.count - 2)")
                        .font(.system(size: 8)).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)

            if hasCompleted {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 8)).foregroundStyle(.green)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .top)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.primary.opacity(inMonth ? 0.04 : 0.0))
        )
        .opacity(inMonth ? 1 : 0.5)
        .contentShape(Rectangle())
    }

    private func chip(for workout: ScheduledWorkoutRecord) -> some View {
        let family = SportFamily(sportKey: workout.sport)
        return Image(systemName: family.icon)
            .font(.system(size: 9))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 2)
            .background(Capsule().fill(family.color))
            .draggable(workout.id)
    }
}

// MARK: - Planned Row (detail list)

private struct PlannedRow: View {
    let workout: ScheduledWorkoutRecord

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
            Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
    }

    private var summaryLine: String {
        var parts: [String] = []
        if workout.targetDurationMinutes > 0 { parts.append(durationHM(workout.targetDurationMinutes)) }
        if targetTSS > 0 { parts.append("\(Int(targetTSS.rounded())) TSS target") }
        return parts.isEmpty ? "Target not set" : parts.joined(separator: "  •  ")
    }
}
