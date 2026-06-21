import SwiftUI

// MARK: - Week view
//
// FEATURES.md "Extended calendar": a 7-day view where each day shows its
// completed activities, planned workouts and real-world commitments together with
// a morning / midday / evening availability strip — so the athlete sees at a glance
// where there's still a clear block to train. Adaptive: side-by-side day columns on
// roomy devices (iPad / macOS / visionOS), stacked full-width day sections on a
// compact iPhone. Drag a planned chip onto another day's segment to reschedule it
// and set its time of day.

struct WeekView: View {
    @Bindable var viewModel: CalendarViewModel
    let useColumns: Bool

    var body: some View {
        if useColumns {
            HStack(alignment: .top, spacing: 6) {
                ForEach(viewModel.weekDays, id: \.self) { day in
                    DayColumn(viewModel: viewModel, day: day)
                        .frame(maxWidth: .infinity, alignment: .top)
                }
            }
        } else {
            VStack(spacing: 10) {
                ForEach(viewModel.weekDays, id: \.self) { day in
                    DayColumn(viewModel: viewModel, day: day)
                }
            }
        }
    }
}

// MARK: - One day

private struct DayColumn: View {
    @Bindable var viewModel: CalendarViewModel
    let day: Date

    private var isToday: Bool { Calendar.current.isDateInToday(day) }
    private var isSelected: Bool { Calendar.current.isDate(day, inSameDayAs: viewModel.selectedDay) }

    var body: some View {
        let planned = viewModel.planned(on: day)
        let completed = viewModel.completed(on: day)
        let busy = viewModel.busyWindows(on: day)

        VStack(alignment: .leading, spacing: 8) {
            header

            // Availability + per-segment drop targets.
            HStack(spacing: 4) {
                ForEach(TimeOfDaySegment.allCases) { segment in
                    segmentPill(segment)
                }
            }

            if completed.isEmpty && planned.isEmpty && busy.isEmpty {
                Text("Free")
                    .font(.caption2).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            ForEach(completed, id: \.id) { CompletedRow(activity: $0) }
            ForEach(planned) { workout in
                PlannedRow(workout: workout,
                           conflict: viewModel.conflict(for: workout),
                           segment: viewModel.assignedSegment(workout))
                    .draggable(workout.id)
            }
            ForEach(busy) { BusyRow(window: $0) }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04))
        )
        .contentShape(Rectangle())
        .onTapGesture { viewModel.selectedDay = Calendar.current.startOfDay(for: day) }
        // Whole-day fallback drop: move to this day, keep any time-of-day.
        .dropDestination(for: String.self) { ids, _ in
            guard let id = ids.first else { return false }
            viewModel.move(workoutID: id, to: day)
            return true
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(day.formatted(.dateTime.weekday(.abbreviated)))
                .font(.caption.weight(.semibold))
                .foregroundStyle(isToday ? Color.accentColor : .secondary)
            Text("\(Calendar.current.component(.day, from: day))")
                .font(.headline)
                .foregroundStyle(isToday ? Color.accentColor : .primary)
            Spacer()
        }
    }

    private func segmentPill(_ segment: TimeOfDaySegment) -> some View {
        let state = viewModel.state(of: segment, on: day)
        return VStack(spacing: 2) {
            Image(systemName: segment.icon).font(.system(size: 9))
            Text(segment.shortLabel).font(.system(size: 9, weight: .semibold))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 5)
        .foregroundStyle(state.color)
        .background(Capsule().fill(state.color.opacity(0.15)))
        .contentShape(Capsule())
        .dropDestination(for: String.self) { ids, _ in
            guard let id = ids.first else { return false }
            viewModel.move(workoutID: id, to: day, segment: segment)
            return true
        }
    }
}
