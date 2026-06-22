import Foundation

// MARK: - Calendar ViewModel
//
// FEATURES.md "Training calendar screen" + "Extended calendar — past workouts and
// daily life context": a Week and a Month view of the athlete's days, each showing
// planned workouts, completed activities and real-world commitments (EventKit), plus
// a per-day time-of-day availability indicator so it's obvious where there is still
// time to train. Reads the local `TrainingDataStore` + `CalendarService` and writes
// reschedules back (locally always, and to Garmin when that's the active source).

enum CalendarMode: String, CaseIterable, Identifiable {
    case week, month
    var id: String { rawValue }
    var label: String { self == .week ? "Week" : "Month" }
}

@MainActor
@Observable
final class CalendarViewModel {
    /// Week vs Month. Persisted so the screen reopens in the last-used mode.
    var mode: CalendarMode {
        didSet {
            guard mode != oldValue else { return }
            UserDefaults.standard.set(mode.rawValue, forKey: Self.modeKey)
            load()
        }
    }

    /// First day of the visible month (start-of-day) — drives the month grid.
    private(set) var visibleMonth: Date
    /// Monday of the visible week — drives the week view.
    private(set) var weekAnchor: Date
    /// The 42 day-cells (6 weeks, Monday-first) covering the visible month.
    private(set) var gridDays: [Date] = []
    /// The 7 days (Monday-first) of the visible week.
    private(set) var weekDays: [Date] = []

    /// Planned workouts keyed by start-of-day.
    private(set) var plannedByDay: [Date: [ScheduledWorkoutRecord]] = [:]
    /// Completed activities keyed by start-of-day.
    private(set) var completedByDay: [Date: [ActivityRecord]] = [:]
    /// Calendar busy windows keyed by start-of-day.
    private(set) var busyByDay: [Date: DayAvailability] = [:]
    /// Per-segment availability keyed by start-of-day.
    private(set) var segmentsByDay: [Date: [TimeOfDaySegment: SegmentState]] = [:]

    /// True when calendar access hasn't been granted, so the UI can offer to ask.
    private(set) var needsCalendarAccess: Bool = false

    /// The day whose detail list is shown below the grid.
    var selectedDay: Date

    private let dataSource: DataSource
    private static let modeKey = "calendar.mode"
    private let cal: Calendar = {
        var c = Calendar.current
        c.firstWeekday = 2 // Monday
        return c
    }()

    init(dataSource: DataSource, today: Date = Date()) {
        self.dataSource = dataSource
        let day = Calendar.current.startOfDay(for: today)
        self.visibleMonth = CalendarViewModel.monthStart(of: day)
        self.weekAnchor = TrainingVolume.weekStart(of: day)
        self.selectedDay = day
        let stored = UserDefaults.standard.string(forKey: Self.modeKey)
        self.mode = stored.flatMap(CalendarMode.init(rawValue:)) ?? .week
    }

    // MARK: - Titles & headers

    var title: String {
        switch mode {
        case .month:
            return visibleMonth.formatted(.dateTime.month(.wide).year())
        case .week:
            guard let end = cal.date(byAdding: .day, value: 6, to: weekAnchor) else {
                return weekAnchor.formatted(.dateTime.month().day())
            }
            let start = weekAnchor.formatted(.dateTime.month(.abbreviated).day())
            let endStr = end.formatted(.dateTime.month(.abbreviated).day())
            return "\(start) – \(endStr)"
        }
    }

    /// Monday-first weekday symbols for the month header row.
    var weekdaySymbols: [String] {
        let symbols = cal.shortStandaloneWeekdaySymbols // [Sun, Mon, …]
        return Array(symbols[1...] + symbols[0...0])     // → [Mon, …, Sun]
    }

    // MARK: - Per-day accessors

    func planned(on day: Date) -> [ScheduledWorkoutRecord] {
        plannedByDay[cal.startOfDay(for: day)] ?? []
    }

    func completed(on day: Date) -> [ActivityRecord] {
        completedByDay[cal.startOfDay(for: day)] ?? []
    }

    func busyWindows(on day: Date) -> [BusyWindow] {
        (busyByDay[cal.startOfDay(for: day)]?.windows ?? []).filter { !$0.isAllDay }
    }

    func segments(on day: Date) -> [TimeOfDaySegment: SegmentState] {
        segmentsByDay[cal.startOfDay(for: day)] ?? [:]
    }

    func state(of segment: TimeOfDaySegment, on day: Date) -> SegmentState {
        segments(on: day)[segment] ?? .free
    }

    func isInVisibleMonth(_ day: Date) -> Bool {
        cal.isDate(day, equalTo: visibleMonth, toGranularity: .month)
    }

    // MARK: - Workout placement

    /// The segment a planned workout is assigned to via its local start time, if any.
    func assignedSegment(_ workout: ScheduledWorkoutRecord) -> TimeOfDaySegment? {
        workout.startMinute.flatMap { TimeOfDaySegment.containing(minute: $0) }
    }

    /// A planned workout conflicts when its assigned segment isn't completely free.
    func conflict(for workout: ScheduledWorkoutRecord) -> Bool {
        guard let segment = assignedSegment(workout) else { return false }
        return state(of: segment, on: workout.date) != .free
    }

    // MARK: - Navigation

    func showPrevious() { mode == .month ? shiftMonth(by: -1) : shiftWeek(by: -1) }
    func showNext() { mode == .month ? shiftMonth(by: 1) : shiftWeek(by: 1) }

    func goToToday() {
        let today = cal.startOfDay(for: Date())
        visibleMonth = Self.monthStart(of: today)
        weekAnchor = TrainingVolume.weekStart(of: today, calendar: cal)
        selectedDay = today
        load()
    }

    private func shiftMonth(by months: Int) {
        guard let next = cal.date(byAdding: .month, value: months, to: visibleMonth) else { return }
        visibleMonth = Self.monthStart(of: next)
        load()
    }

    private func shiftWeek(by weeks: Int) {
        guard let next = cal.date(byAdding: .day, value: weeks * 7, to: weekAnchor) else { return }
        weekAnchor = TrainingVolume.weekStart(of: next, calendar: cal)
        if !weekDays.contains(where: { cal.isDate($0, inSameDayAs: selectedDay) }) {
            selectedDay = weekAnchor
        }
        load()
    }

    // MARK: - Loading

    func load() {
        let (start, end) = currentRange()

        switch mode {
        case .month:
            gridDays = (0..<42).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
            weekDays = []
        case .week:
            weekDays = (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
            gridDays = []
        }

        let store = TrainingDataStore.shared

        var completed: [Date: [ActivityRecord]] = [:]
        for r in store.activities(from: start, to: end) {
            completed[cal.startOfDay(for: r.date), default: []].append(r)
        }
        completedByDay = completed

        // Drop plans already fulfilled by a completed activity on the same day so
        // a done session doesn't render twice in the grid / day detail.
        var planned: [Date: [ScheduledWorkoutRecord]] = [:]
        for w in store.scheduledWorkouts(from: start, to: end) {
            planned[cal.startOfDay(for: w.date), default: []].append(w)
        }
        plannedByDay = planned.mapValues {
            PlanReconciliation.unfulfilled(planned: $0, completed: completed[cal.startOfDay(for: $0[0].date)] ?? [])
        }

        loadCalendar(from: start, to: end)
    }

    /// Load EventKit busy windows + derived segment states for the range. Skipped
    /// (and flagged) when access hasn't been granted.
    private func loadCalendar(from start: Date, to end: Date) {
        let service = CalendarService.shared
        guard service.accessState == .authorized else {
            needsCalendarAccess = true
            busyByDay = [:]
            segmentsByDay = [:]
            return
        }
        needsCalendarAccess = false
        var busy: [Date: DayAvailability] = [:]
        var segs: [Date: [TimeOfDaySegment: SegmentState]] = [:]
        for day in service.availability(from: start, to: end) {
            let key = cal.startOfDay(for: day.date)
            busy[key] = day
            segs[key] = DaySegments.states(for: day, calendar: cal)
        }
        busyByDay = busy
        segmentsByDay = segs
    }

    /// Request EventKit access from an inline prompt, then reload on success.
    func requestCalendarAccess() async {
        let granted = await CalendarService.shared.requestAccess()
        if granted { load() } else { needsCalendarAccess = true }
    }

    // MARK: - Reschedule

    /// Move a planned workout to `newDay` and, when `segment` is given, anchor its
    /// local start time to that segment. Updates the local store immediately and,
    /// for Garmin-sourced workouts on the Garmin data source, pushes the day move to
    /// Garmin in the background.
    func move(workoutID: String, to newDay: Date, segment: TimeOfDaySegment? = nil) {
        let store = TrainingDataStore.shared
        let target = cal.startOfDay(for: newDay)
        let (start, end) = currentRange()
        guard let record = store.scheduledWorkouts(from: start, to: end)
            .first(where: { $0.id == workoutID }) else { return }
        let fromDay = cal.startOfDay(for: record.date)
        let dayChanged = fromDay != target
        let minuteChanged = segment != nil && record.startMinute != segment?.anchorMinute
        guard dayChanged || minuteChanged else { return }

        let source = record.source
        let garminID = record.id.hasPrefix("garmin:") ? String(record.id.dropFirst("garmin:".count)) : nil

        if dayChanged { store.moveScheduledWorkout(id: workoutID, to: target) }
        if let segment { store.setScheduledStartMinute(id: workoutID, minute: segment.anchorMinute) }
        load()

        if dayChanged, dataSource == .garmin, source == "garmin", let garminID {
            let from = DateFormatter.ymd.string(from: fromDay)
            let to = DateFormatter.ymd.string(from: target)
            Task { _ = await GarminService.shared.moveWorkout(workoutId: garminID, toDate: to, fromDate: from) }
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

    /// The day range currently loaded, depending on mode.
    private func currentRange() -> (start: Date, end: Date) {
        switch mode {
        case .month:
            let start = TrainingVolume.weekStart(of: visibleMonth, calendar: cal)
            let end = cal.date(byAdding: .day, value: 41, to: start) ?? start
            return (start, end)
        case .week:
            let end = cal.date(byAdding: .day, value: 6, to: weekAnchor) ?? weekAnchor
            return (weekAnchor, end)
        }
    }

    private static func monthStart(of date: Date) -> Date {
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month], from: date)
        return cal.date(from: comps) ?? cal.startOfDay(for: date)
    }
}
