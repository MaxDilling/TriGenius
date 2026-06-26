import Foundation

// MARK: - Calendar ViewModel
//
// FEATURES.md "Training calendar screen" + "Extended calendar — past workouts and
// daily life context": a Week and a Month view of the athlete's days, each showing
// planned workouts, completed activities and real-world commitments (EventKit), plus
// a per-day time-of-day availability indicator so it's obvious where there is still
// time to train. Reads the local `TrainingDataStore` + `CalendarService` and writes
// reschedules back (locally always, and to Garmin when that's the active source).
//
// Layout mirrors Apple Calendar: the month is a horizontally paged grid; the week is
// a continuously-scrollable multi-day time grid. Both render from a bounded-but-large
// list of days/months (≈1 year / ±2 years) so scrolling feels endless without an
// unbounded view tree; the loaded *data* window slides as the grid scrolls.

enum CalendarMode: String {
    case week, month
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

    /// Month the month view's header shows (updated as the continuous grid scrolls).
    private(set) var visibleMonth: Date
    /// Week-start the month grid should scroll to (set on drill-out / Today).
    private(set) var monthFocusWeek: Date
    /// Bumped whenever the month grid should programmatically scroll to `monthFocusWeek`.
    private(set) var monthScrollTick = 0
    /// The day the week grid should scroll to (set when drilling in from the month).
    private(set) var weekFocusDay: Date
    /// Bumped whenever the week grid should programmatically scroll to `weekFocusDay`.
    /// A separate trigger (vs. observing `weekFocusDay`) so "Today" still scrolls even
    /// when the focus day is unchanged (e.g. already today after manual scrolling).
    private(set) var weekScrollTick = 0
    /// Leftmost day currently visible in the week grid — drives the title + date
    /// strip. Updated by the grid as it scrolls.
    var firstVisibleDay: Date

    /// Bounded continuous day list backing the week grid (≈ today ± 6 months).
    let weekGridDays: [Date]
    /// `weekGridDays` → index, so the grid can map the leftmost visible day to a
    /// position in O(1) instead of a per-frame linear `isDate(inSameDayAs:)` scan.
    @ObservationIgnored private lazy var weekGridIndexByDay: [Date: Int] =
        Dictionary(uniqueKeysWithValues: weekGridDays.enumerated().map { ($1, $0) })
    /// Bounded continuous week-start list backing the month grid (≈ today ± 1.5 years).
    let monthScrollWeeks: [Date]

    /// Planned workouts keyed by start-of-day.
    private(set) var plannedByDay: [Date: [ScheduledWorkoutRecord]] = [:]
    /// Completed activities keyed by start-of-day.
    private(set) var completedByDay: [Date: [ActivityRecord]] = [:]
    /// Calendar busy windows keyed by start-of-day.
    private(set) var busyByDay: [Date: DayAvailability] = [:]
    /// Per-segment availability keyed by start-of-day.
    private(set) var segmentsByDay: [Date: [TimeOfDaySegment: SegmentState]] = [:]
    /// The day range currently loaded into the dictionaries above.
    private var loadedRange: ClosedRange<Date>?

    /// True when calendar access hasn't been granted, so the UI can offer to ask.
    private(set) var needsCalendarAccess: Bool = false

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
        var c = Calendar.current
        c.firstWeekday = 2
        let weekStartOfDay = TrainingVolume.weekStart(of: day, calendar: c)
        self.visibleMonth = CalendarViewModel.monthStart(of: day)
        self.monthFocusWeek = weekStartOfDay
        self.weekFocusDay = day
        self.firstVisibleDay = day

        // Bounded-but-large backing ranges so scrolling feels continuous.
        self.weekGridDays = (-182...182).compactMap { c.date(byAdding: .day, value: $0, to: weekStartOfDay) }
        self.monthScrollWeeks = (-78...78).compactMap { c.date(byAdding: .weekOfYear, value: $0, to: weekStartOfDay) }

        let stored = UserDefaults.standard.string(forKey: Self.modeKey)
        self.mode = stored.flatMap(CalendarMode.init(rawValue:)) ?? .week
    }

    // MARK: - Titles & headers

    /// Month name shown in the nav pill (and the "zoom out" target label).
    var monthLabel: String {
        let day = mode == .month ? visibleMonth : firstVisibleDay
        return day.formatted(.dateTime.month(.wide))
    }

    /// Monday-first weekday symbols for the month header row.
    var weekdaySymbols: [String] {
        let symbols = cal.shortStandaloneWeekdaySymbols // [Sun, Mon, …]
        return Array(symbols[1...] + symbols[0...0])     // → [Mon, …, Sun]
    }

    /// ISO week number for a day (used by the week grid's gutter, e.g. "W27").
    func weekNumber(for day: Date) -> Int {
        cal.component(.weekOfYear, from: day)
    }

    /// Position of `day` in `weekGridDays` (O(1)), or nil if outside the backing range.
    func weekGridIndex(of day: Date) -> Int? {
        weekGridIndexByDay[cal.startOfDay(for: day)]
    }

    // MARK: - Per-day accessors

    func planned(on day: Date) -> [ScheduledWorkoutRecord] {
        plannedByDay[cal.startOfDay(for: day)] ?? []
    }

    func completed(on day: Date) -> [ActivityRecord] {
        completedByDay[cal.startOfDay(for: day)] ?? []
    }

    /// Timed (non-all-day) calendar commitments — positioned inside the hour grid.
    func busyWindows(on day: Date) -> [BusyWindow] {
        (busyByDay[cal.startOfDay(for: day)]?.windows ?? []).filter { !$0.isAllDay }
    }

    /// All-day calendar commitments — shown in the all-day band with workouts.
    func allDayWindows(on day: Date) -> [BusyWindow] {
        (busyByDay[cal.startOfDay(for: day)]?.windows ?? []).filter { $0.isAllDay }
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

    /// Drill from the month into the week grid, scrolled to `day`.
    func focusWeek(on day: Date) {
        let target = cal.startOfDay(for: day)
        weekFocusDay = target
        firstVisibleDay = target
        weekScrollTick += 1
        mode = .week   // didSet → load() → week window around weekFocusDay
    }

    /// Scroll the week grid to `day` (from a date-strip tap) without changing mode.
    func scrollWeek(to day: Date) {
        let target = cal.startOfDay(for: day)
        weekFocusDay = target
        firstVisibleDay = target   // anchor the strip's circle on the new leftmost day
        weekScrollTick += 1
        ensureWeekLoaded(around: target)
    }

    /// Zoom back out from the week grid to the month containing the visible days.
    func showMonth() {
        visibleMonth = Self.monthStart(of: firstVisibleDay)
        monthFocusWeek = TrainingVolume.weekStart(of: firstVisibleDay, calendar: cal)
        monthScrollTick += 1
        mode = .month   // didSet → load()
    }

    func goToToday() {
        let today = cal.startOfDay(for: Date())
        firstVisibleDay = today
        switch mode {
        case .month:
            visibleMonth = Self.monthStart(of: today)
            monthFocusWeek = TrainingVolume.weekStart(of: today, calendar: cal)
            monthScrollTick += 1
            loadWeekWindow(around: today)
        case .week:
            weekFocusDay = today
            weekScrollTick += 1
            loadWeekWindow(around: today)
        }
    }

    // MARK: - Loading

    func load() {
        switch mode {
        case .month: loadWeekWindow(around: monthFocusWeek)
        case .week: loadWeekWindow(around: weekFocusDay)
        }
    }

    /// The 7 Monday-first days of the week starting at `weekStart` (month grid rows).
    func weekDays(for weekStart: Date) -> [Date] {
        (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: weekStart) }
    }

    /// Update the month header + load window as the continuous month grid scrolls.
    /// The header shows the month of the row's midweek day (its dominant month).
    func updateMonthScroll(topWeekStart: Date) {
        let midweek = cal.date(byAdding: .day, value: 3, to: topWeekStart) ?? topWeekStart
        visibleMonth = Self.monthStart(of: midweek)
        ensureWeekLoaded(around: topWeekStart)
    }

    /// Load a window around `day` for the continuous grids. Skewed forward (8 weeks
    /// back, 12 ahead) because the month view pins its focus week to the *top*, so the
    /// weeks visible below it — which the user sees immediately — are in the future and
    /// must already be loaded (otherwise their events pop in only after scrolling).
    func loadWeekWindow(around day: Date) {
        let center = TrainingVolume.weekStart(of: day, calendar: cal)
        let start = cal.date(byAdding: .day, value: -8 * 7, to: center) ?? center
        let end = cal.date(byAdding: .day, value: 12 * 7 - 1, to: center) ?? center
        loadData(from: start, to: end)
    }

    /// Called by the week grid as it scrolls. Reloads only when `day` nears the edge
    /// of the loaded window, so most scrolling needs no work.
    func ensureWeekLoaded(around day: Date) {
        if let r = loadedRange,
           let safeLo = cal.date(byAdding: .day, value: 14, to: r.lowerBound),
           let safeHi = cal.date(byAdding: .day, value: -14, to: r.upperBound),
           day >= safeLo, day <= safeHi {
            return
        }
        loadWeekWindow(around: day)
    }

    /// Fill the per-day dictionaries for `[start, end]` from the local store + EventKit.
    private func loadData(from start: Date, to end: Date) {
        let store = TrainingDataStore.shared

        var completed: [Date: [ActivityRecord]] = [:]
        for r in store.activities(from: start, to: end) {
            completed[cal.startOfDay(for: r.date), default: []].append(r)
        }
        completedByDay = completed

        // `openScheduledWorkouts` drops plans whose completion has landed, so a
        // done session doesn't render twice in the grid / day detail.
        var planned: [Date: [ScheduledWorkoutRecord]] = [:]
        for w in store.openScheduledWorkouts(from: start, to: end) {
            planned[cal.startOfDay(for: w.date), default: []].append(w)
        }
        plannedByDay = planned

        loadCalendar(from: start, to: end)
        loadedRange = cal.startOfDay(for: start)...cal.startOfDay(for: end)
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
        guard let record = scheduledRecord(id: workoutID) else { return }
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

    /// Find a scheduled workout by id within the loaded window (falls back to a wide
    /// store lookup so a drag that crosses the window edge still resolves).
    private func scheduledRecord(id: String) -> ScheduledWorkoutRecord? {
        if let hit = plannedByDay.values.flatMap({ $0 }).first(where: { $0.id == id }) { return hit }
        guard let r = loadedRange else { return nil }
        return TrainingDataStore.shared.scheduledWorkouts(from: r.lowerBound, to: r.upperBound)
            .first(where: { $0.id == id })
    }

    // MARK: - Date helpers

    private static func monthStart(of date: Date) -> Date {
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month], from: date)
        return cal.date(from: comps) ?? cal.startOfDay(for: date)
    }
}
