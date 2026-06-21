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
        // One GlassEffectContainer so the day columns' glass blends as a group
        // instead of stacking many independent glass layers.
        GlassEffectContainer(spacing: 6) {
            if useColumns {
                HStack(alignment: .top, spacing: 6) {
                    ForEach(viewModel.weekDays, id: \.self) { day in
                        DayColumn(viewModel: viewModel, day: day)
                            .frame(maxWidth: .infinity, alignment: .top)
                    }
                }
            } else {
                VStack(spacing: Theme.Spacing.s) {
                    ForEach(viewModel.weekDays, id: \.self) { day in
                        DayColumn(viewModel: viewModel, day: day)
                    }
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

        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            header

            // Slim free/busy indicator: three segments that also serve as
            // time-of-day drop targets for drag-to-reschedule. Only shown when
            // the calendar is linked — without it there's no availability to
            // report, and an all-green bar would be misleading.
            if !viewModel.segments(on: day).isEmpty {
                HStack(spacing: 3) {
                    ForEach(TimeOfDaySegment.allCases) { segment in
                        segmentDropTarget(segment)
                    }
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
        .padding(Theme.Spacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Container inversion: the whole day is a single glass surface, not a
        // stack of individual floating cards. Selection is a subtle accent
        // hairline rather than a heavy fill.
        .glassSurface(cornerRadius: Theme.Radius.m)
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 2)
            }
        }
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

    private func segmentDropTarget(_ segment: TimeOfDaySegment) -> some View {
        let state = viewModel.state(of: segment, on: day)
        // Slim colored bar (visual), wrapped in a taller transparent hit area so
        // it stays an easy drop target despite the compact look.
        return Capsule()
            .fill(state.color.opacity(0.85))
            .frame(height: 6)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .dropDestination(for: String.self) { ids, _ in
                guard let id = ids.first else { return false }
                viewModel.move(workoutID: id, to: day, segment: segment)
                return true
            }
    }
}
