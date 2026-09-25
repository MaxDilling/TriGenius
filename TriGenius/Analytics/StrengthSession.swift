import Foundation

// MARK: - Live strength session
//
// One planned strength session worked through in the app, set by set. The plan's
// blocks become units in execution order — an exercise's sets, or a circuit
// unrolled round by round — and every set carries the rest that follows it (the
// plan's set rest, its `rest_after` or rest step, a circuit's round rest). The
// athlete may reorder, pull forward, push back, swap or add units; that changes
// only this session's record, never the plan.
//
// Every phase is anchored on a `Date`, never on a tick count, so the state is
// exact after the app was backgrounded or relaunched from the saved file: a
// timed rest that ran out while nobody looked reads as over (`settle`).

nonisolated struct StrengthSession: Codable, Hashable, Sendable {
    typealias SetRow = StrengthSets.SetRow

    nonisolated struct Unit: Codable, Hashable, Sendable, Identifiable {
        var id: Int
        /// Prescribed sets in the order they are done; each set's `rest` is the
        /// pause after it.
        var sets: [SetRow]
        /// Sets done so far — always the first `done`.
        var done = 0
        /// Swapped in for today → the exercise it replaced, by title.
        var replaced: [String: String] = [:]

        var isFinished: Bool { done >= sets.count }
        var current: SetRow? { sets.indices.contains(done) ? sets[done] : nil }

        /// Distinct exercises in order ("Push-up + Russian twist" for a circuit).
        var title: String {
            sets.reduce(into: [String]()) { if !$0.contains($1.title) { $0.append($1.title) } }
                .joined(separator: " + ")
        }
    }

    nonisolated enum Phase: Codable, Hashable, Sendable {
        /// Getting ready for, or doing, a rep set; a hold waiting to be started.
        case working(since: Date)
        /// A hold running since `since`, ending on its own at its target.
        case holding(since: Date)
        /// The pause after a logged set: until `until`, or until the athlete moves
        /// on when nil.
        case resting(since: Date, until: Date?)
    }

    /// One logged set and the unit it belongs to.
    nonisolated struct Logged: Codable, Hashable, Sendable {
        var unit: Int
        var set: SetRow
    }

    let planId: String
    let planName: String
    let sport: String
    /// The plan's duration, 0 when it has none.
    let plannedMinutes: Double
    let startedAt: Date
    var units: [Unit]
    var log: [Logged] = []
    var phase: Phase
    var pausedAt: Date?
    var pausedSeconds: Double = 0
    var endedAt: Date?
    /// The athlete's changes to the current set before logging it.
    var edited: SetRow?
    /// Session RPE 1–10, when the athlete gave one.
    var rpe: Int?

    init(planId: String, planName: String, sport: String, plannedMinutes: Double,
         steps: [[String: Any]], at now: Date) {
        self.planId = planId
        self.planName = planName
        self.sport = sport
        self.plannedMinutes = plannedMinutes
        startedAt = now
        units = Self.units(planned: steps)
        phase = .working(since: now)
    }

    /// The plan's blocks as units. A rest step, or an exercise's `rest_after`,
    /// becomes the rest after the set before it; a circuit's round rest follows
    /// every round but the last.
    static func units(planned steps: [[String: Any]]) -> [Unit] {
        var units: [Unit] = []
        for block in StrengthSets.blocks(planned: steps) {
            var round: [SetRow] = []
            for item in block.items {
                switch item {
                case .exercise(let lines):
                    round += lines.compactMap(\.set)
                case .rest(let rest):
                    if !round.isEmpty {
                        round[round.count - 1].rest = rest
                    } else if let last = units.indices.last {
                        units[last].sets[units[last].sets.count - 1].rest = rest
                    }
                }
            }
            guard !round.isEmpty else { continue }
            var sets: [SetRow] = []
            for index in 0..<block.rounds {
                var pass = round
                if index < block.rounds - 1, let seconds = block.roundRestSeconds {
                    pass[pass.count - 1].rest = .timed(seconds: seconds)
                }
                sets += pass
            }
            units.append(Unit(id: units.count, sets: sets))
        }
        return units
    }

    // MARK: Reading

    var performed: [SetRow] { log.map(\.set) }
    var totalSets: Int { units.reduce(0) { $0 + $1.sets.count } }
    var doneSets: Int { units.reduce(0) { $0 + $1.done } }
    var currentIndex: Int? { units.firstIndex { !$0.isFinished } }
    var current: SetRow? { currentIndex.flatMap { units[$0].current } }
    var isComplete: Bool { currentIndex == nil }
    var upcoming: [Unit] { currentIndex.map { Array(units[($0 + 1)...]).filter { !$0.isFinished } } ?? [] }

    /// Where the current set sits among its exercise's sets in its unit — for a
    /// circuit, the round.
    var currentSetPosition: (number: Int, of: Int)? {
        guard let index = currentIndex, let set = current else { return nil }
        let unit = units[index]
        let same = unit.sets.indices.filter { unit.sets[$0].sameExercise(as: set) }
        return (same.filter { $0 < unit.done }.count + 1, same.count)
    }

    /// The current set as it will be logged: the athlete's changes, else the
    /// prescription at the weight last logged for the exercise in this session.
    var draft: SetRow? {
        if let edited { return edited }
        guard var set = current else { return nil }
        if let last = log.last(where: { $0.set.sameExercise(as: set) }) { set.weightKg = last.set.weightKg }
        return set
    }

    /// Active time — wall time less every pause, up to `now` or the end.
    func elapsed(at now: Date) -> TimeInterval {
        let end = endedAt ?? now
        return end.timeIntervalSince(startedAt) - pausedSeconds - (pausedAt.map { end.timeIntervalSince($0) } ?? 0)
    }

    /// The phase as of `now` — frozen while paused — with a timed rest that has
    /// run out read as the next set's start.
    func phase(at now: Date) -> Phase {
        if case .resting(_, let until?) = phase, until <= pausedAt ?? now { return .working(since: until) }
        return phase
    }

    // MARK: Moving through the session

    /// Close a timed rest that ran out: the rest it lasted goes onto the set
    /// before it.
    mutating func settle(at now: Date) {
        guard pausedAt == nil, case .resting(_, let until?) = phase, until <= now else { return }
        endRest(at: until)
    }

    /// Log the current set as done — `set` carries what was actually done — and
    /// move on to its rest, or straight to the next set when none follows. The
    /// last set ends the session.
    mutating func complete(_ set: SetRow, at now: Date) {
        settle(at: now)
        guard let index = currentIndex else { return }
        var logged = set
        logged.rest = nil
        log.append(Logged(unit: units[index].id, set: logged))
        let rest = units[index].current?.rest
        units[index].done += 1
        edited = nil
        guard !isComplete else { phase = .working(since: now); endedAt = now; return }
        switch rest {
        case .timed(let seconds): phase = .resting(since: now, until: now.addingTimeInterval(seconds))
        case .lapButton: phase = .resting(since: now, until: nil)
        case nil: phase = .working(since: now)
        }
    }

    /// Start the current hold.
    mutating func startHold(at now: Date) {
        settle(at: now)
        if case .working = phase { phase = .holding(since: now) }
    }

    mutating func skipRest(at now: Date) {
        settle(at: now)
        if case .resting = phase { endRest(at: now) }
    }

    /// Lengthen or shorten a timed rest, never below what has already passed.
    mutating func adjustRest(by seconds: TimeInterval, at now: Date) {
        settle(at: now)
        guard case .resting(let since, let until?) = phase else { return }
        phase = .resting(since: since, until: max(now, until.addingTimeInterval(seconds)))
    }

    private mutating func endRest(at end: Date) {
        guard case .resting(let since, _) = phase else { return }
        if !log.isEmpty { log[log.count - 1].set.restSeconds = end.timeIntervalSince(since).rounded() }
        phase = .working(since: end)
    }

    mutating func pause(at now: Date) {
        guard pausedAt == nil else { return }
        settle(at: now)
        pausedAt = now
    }

    /// Resume, shifting the running phase by the pause so no rest or hold ran on.
    mutating func resume(at now: Date) {
        guard let pausedAt else { return }
        let paused = now.timeIntervalSince(pausedAt)
        pausedSeconds += paused
        self.pausedAt = nil
        switch phase {
        case .working(let since): phase = .working(since: since.addingTimeInterval(paused))
        case .holding(let since): phase = .holding(since: since.addingTimeInterval(paused))
        case .resting(let since, let until):
            phase = .resting(since: since.addingTimeInterval(paused), until: until?.addingTimeInterval(paused))
        }
    }

    mutating func end(at now: Date) {
        if pausedAt != nil { resume(at: now) }
        settle(at: now)
        endedAt = now
    }

    // MARK: Changing the session

    /// Change the current set before logging it.
    mutating func edit(_ set: SetRow) {
        edited = set
    }

    /// Correct the last logged set.
    mutating func editLast(reps: Int?, seconds: Double?, weightKg: Double?) {
        guard !log.isEmpty else { return }
        log[log.count - 1].set.reps = reps
        log[log.count - 1].set.seconds = seconds
        log[log.count - 1].set.weightKg = weightKg
    }

    /// Rate the last logged set; nil clears the rating.
    mutating func rateLast(_ effort: StrengthSets.Effort?) {
        guard !log.isEmpty else { return }
        log[log.count - 1].set.effort = effort
    }

    /// Do the unit next — before the current one, which keeps its progress.
    mutating func doNow(unit id: Int) {
        guard let current = currentIndex, let from = units.firstIndex(where: { $0.id == id }), from > current else { return }
        units.insert(units.remove(at: from), at: current)
        edited = nil
    }

    /// Push the current unit behind everything still to do.
    mutating func moveCurrentToEnd() {
        guard let current = currentIndex, !upcoming.isEmpty else { return }
        units.append(units.remove(at: current))
        edited = nil
    }

    /// Reorder the upcoming units (`upcoming` indices).
    mutating func moveUpcoming(from source: IndexSet, to destination: Int) {
        guard let current = currentIndex else { return }
        let moved = source.map { self.upcoming[$0] }
        var upcoming = self.upcoming.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        upcoming.insert(contentsOf: moved, at: destination - source.count { $0 < destination })
        units = units.filter(\.isFinished) + [units[current]] + upcoming
    }

    /// Put `exercise` in place of every set still to do of `old` in the unit.
    /// The prescription carries over; `reps` / `seconds` replace each set's own
    /// where given, the weight is the one given.
    mutating func swap(unit id: Int, replacing old: SetRow, with exerciseId: String, name: String,
                       reps: Int? = nil, seconds: Double? = nil, weightKg: Double?) {
        guard let index = units.firstIndex(where: { $0.id == id }) else { return }
        let replacedTitle = old.title
        for i in units[index].done..<units[index].sets.count where units[index].sets[i].sameExercise(as: old) {
            units[index].sets[i].exerciseId = exerciseId
            units[index].sets[i].exerciseName = name
            units[index].sets[i].exerciseCategory = nil
            units[index].sets[i].weightKg = weightKg
            if let reps { units[index].sets[i].reps = reps }
            if let seconds { units[index].sets[i].seconds = seconds }
        }
        units[index].replaced[name] = units[index].replaced[replacedTitle] ?? replacedTitle
        units[index].replaced[replacedTitle] = nil
        edited = nil
    }

    /// Add an exercise's sets after everything still to do.
    mutating func append(sets: [SetRow]) {
        guard !sets.isEmpty else { return }
        units.append(Unit(id: (units.map(\.id).max() ?? -1) + 1, sets: sets))
    }
}
