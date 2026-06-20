import Foundation

// MARK: - Calendar ViewModel
//
// FEATURES.md "Training calendar screen" + "Drag-and-drop workout reschedule":
// a month grid of scheduled + completed workouts, reading the local
// `TrainingDataStore` and writing reschedules back (locally always, and to
// Garmin when that's the active source).

@MainActor
@Observable
final class CalendarViewModel {
    /// First day of the visible month (start-of-day).
    private(set) var visibleMonth: Date
    /// The 42 day-cells (6 weeks, Monday-first) covering the visible month.
    private(set) var gridDays: [Date] = []
    /// Planned workouts keyed by start-of-day.
    private(set) var plannedByDay: [Date: [ScheduledWorkoutRecord]] = [:]
    /// Days that have at least one completed activity (for the cell marker).
    private(set) var completedDays: Set<Date> = []
    /// The day whose detail list is shown below the grid.
    var selectedDay: Date

    private let dataSource: DataSource
    private let cal: Calendar = {
        var c = Calendar.current
        c.firstWeekday = 2 // Monday
        return c
    }()

    init(dataSource: DataSource, today: Date = Date()) {
        self.dataSource = dataSource
        let monthStart = Calendar.current.startOfDay(for: today)
        self.visibleMonth = CalendarViewModel.monthStart(of: monthStart)
        self.selectedDay = Calendar.current.startOfDay(for: today)
    }

    var monthTitle: String {
        visibleMonth.formatted(.dateTime.month(.wide).year())
    }

    /// Monday-first weekday symbols for the header row.
    var weekdaySymbols: [String] {
        let symbols = cal.shortStandaloneWeekdaySymbols // [Sun, Mon, …]
        return Array(symbols[1...] + symbols[0...0])     // → [Mon, …, Sun]
    }

    func planned(on day: Date) -> [ScheduledWorkoutRecord] {
        plannedByDay[cal.startOfDay(for: day)] ?? []
    }

    func hasCompleted(on day: Date) -> Bool {
        completedDays.contains(cal.startOfDay(for: day))
    }

    func isInVisibleMonth(_ day: Date) -> Bool {
        cal.isDate(day, equalTo: visibleMonth, toGranularity: .month)
    }

    // MARK: - Navigation

    func showPreviousMonth() { shiftMonth(by: -1) }
    func showNextMonth() { shiftMonth(by: 1) }
    func goToToday() {
        let today = Calendar.current.startOfDay(for: Date())
        visibleMonth = Self.monthStart(of: today)
        selectedDay = today
        load()
    }

    private func shiftMonth(by months: Int) {
        guard let next = cal.date(byAdding: .month, value: months, to: visibleMonth) else { return }
        visibleMonth = Self.monthStart(of: next)
        load()
    }

    // MARK: - Loading

    func load() {
        let store = TrainingDataStore.shared
        let start = gridStart()
        guard let end = cal.date(byAdding: .day, value: 41, to: start) else { return }

        gridDays = (0..<42).compactMap { cal.date(byAdding: .day, value: $0, to: start) }

        var byDay: [Date: [ScheduledWorkoutRecord]] = [:]
        for w in store.scheduledWorkouts(from: start, to: end) {
            byDay[cal.startOfDay(for: w.date), default: []].append(w)
        }
        plannedByDay = byDay

        let records = store.activities(since: start)
        let endOfRange = cal.startOfDay(for: end)
        completedDays = Set(records
            .map { cal.startOfDay(for: $0.date) }
            .filter { $0 <= endOfRange })
    }

    // MARK: - Reschedule

    /// Move a planned workout to `newDay`. Updates the local store immediately and,
    /// for Garmin-sourced workouts on the Garmin data source, pushes the move to
    /// Garmin in the background. No-op when the target day already holds it.
    func move(workoutID: String, to newDay: Date) {
        let store = TrainingDataStore.shared
        let target = cal.startOfDay(for: newDay)
        guard let record = store.scheduledWorkouts(from: gridStart(),
                                                   to: cal.date(byAdding: .day, value: 41, to: gridStart()) ?? newDay)
            .first(where: { $0.id == workoutID }) else { return }
        let fromDay = cal.startOfDay(for: record.date)
        guard fromDay != target else { return }

        let source = record.source
        let garminID = record.id.hasPrefix("garmin:") ? String(record.id.dropFirst("garmin:".count)) : nil

        store.moveScheduledWorkout(id: workoutID, to: target)
        load()

        if dataSource == .garmin, source == "garmin", let garminID {
            let from = DataSyncCoordinator.ymd.string(from: fromDay)
            let to = DataSyncCoordinator.ymd.string(from: target)
            Task { _ = await GarminService.shared.moveWorkout(fromDate: from, toDate: to, workoutId: garminID) }
        }
    }

    /// Projected planned load (minutes / TSS) for the week containing `selectedDay`.
    func selectedWeekLoad() -> (minutes: Double, tss: Double) {
        let weekStart = TrainingVolume.weekStart(of: selectedDay, calendar: cal)
        guard let weekEnd = cal.date(byAdding: .day, value: 6, to: weekStart) else { return (0, 0) }
        let workouts = TrainingDataStore.shared.scheduledWorkouts(from: weekStart, to: weekEnd)
        var minutes = 0.0, tss = 0.0
        for w in workouts {
            minutes += w.targetDurationMinutes
            let family = SportFamily(sportKey: w.sport)
            tss += w.targetTSS ?? WeeklyTargets.estimatedTSS(family: family, minutes: w.targetDurationMinutes)
        }
        return (minutes, tss)
    }

    // MARK: - Date helpers

    private func gridStart() -> Date {
        TrainingVolume.weekStart(of: visibleMonth, calendar: cal)
    }

    private static func monthStart(of date: Date) -> Date {
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month], from: date)
        return cal.date(from: comps) ?? cal.startOfDay(for: date)
    }
}
