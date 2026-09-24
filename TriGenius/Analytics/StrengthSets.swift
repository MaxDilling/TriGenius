import Foundation

// MARK: - Strength: one set table for the plan and the session
//
// A planned strength session (`stepsJSON`: exercise and rest steps, circuits as
// repeat blocks) keeps its structure (`blocks`); a recorded one
// (`details["strength"]["exercises"]`: consecutive sets grouped per exercise) is
// a flat set list (`rows`), paired set by set with its plan (`comparison`). Both
// are the same `SetRow`, so one table shows either.
//
// The review (Tissue Load handoff D6 — flag only the sets that need the
// athlete's eye) matches on Garmin's exercise key (`ExerciseLibrary`'s
// `garminName`), which both sides carry verbatim — never on a name similarity.
// An exercise the plan didn't contain is not a discrepancy: improvising is
// allowed, and only a set that was *prescribed* can miss its prescription.
//
// Rests are where the watch asks for the reps it counted, so a top-level
// exercise always ends on one before the next step (`restAfter`) — until the lap
// button unless the plan says otherwise. Circuit members follow each other
// directly; their round ends on the circuit's round rest.

nonisolated enum StrengthSets {

    nonisolated enum Rest: Hashable, Sendable {
        case timed(seconds: Double)
        /// Until the athlete presses lap.
        case lapButton
    }

    nonisolated struct SetRow: Hashable, Sendable {
        /// `ExerciseLibrary` id — a plan's, or an athlete-edited recorded set's.
        var exerciseId: String?
        /// As stored: the plan's display name, Garmin's key for a recorded set
        /// ("DUMBBELL_BICEPS_CURL"), or the athlete's custom name. Nil for a set
        /// the watch counted but couldn't name.
        var exerciseName: String?
        /// Garmin's category — present exactly when `exerciseName` is Garmin's key.
        var exerciseCategory: String?
        var reps: Int?
        /// A hold's target, or how long a recorded set took.
        var seconds: Double?
        /// Nil = bodyweight.
        var weightKg: Double?
        /// Rest after this set; nil where none follows.
        var rest: Rest?

        /// A timed rest, the only kind a recorded set carries.
        var restSeconds: Double? {
            get { if case .timed(let seconds) = rest { seconds } else { nil } }
            set { rest = newValue.map { .timed(seconds: $0) } }
        }

        /// The key plan and record pair on: Garmin's name for the exercise, else
        /// the stored name (an exercise Garmin's catalog lacks, or a custom one).
        var garminKey: String? {
            exerciseId.flatMap { ExerciseLibrary.find(id: $0)?.garminName } ?? exerciseName
        }

        var title: String {
            if let exercise = exerciseId.flatMap(ExerciseLibrary.find(id:)) { return exercise.name }
            guard let name = exerciseName, !name.isEmpty else { return "Unnamed set" }
            guard exerciseCategory != nil else { return name }
            if let exercise = ExerciseLibrary.find(garminName: name) { return exercise.name }
            let words = name.replacingOccurrences(of: "_", with: " ").lowercased()
            return words.prefix(1).uppercased() + words.dropFirst()
        }

        /// Same exercise as `other`, i.e. the two sets belong in one group.
        func sameExercise(as other: SetRow) -> Bool {
            exerciseId == other.exerciseId && exerciseName == other.exerciseName
                && exerciseCategory == other.exerciseCategory
        }
    }

    /// One table line: a set, and beside a recorded set the one planned for it.
    nonisolated struct Line: Hashable, Sendable {
        /// What was done — in a plan, what is prescribed. Nil for a planned set
        /// nothing was recorded for.
        var set: SetRow?
        /// The prescribed set a recorded one is matched to.
        var plan: SetRow?
        /// Counted differently than prescribed, or not counted at all.
        var isFlagged = false

        var title: String { (set ?? plan)?.title ?? "" }
    }

    nonisolated enum Item: Hashable, Sendable {
        case exercise([Line])
        case rest(Rest)

        var lines: [Line] {
            if case .exercise(let lines) = self { return lines }
            return []
        }
    }

    /// One plan step — or a whole recorded session. `rounds` > 1 is a circuit.
    nonisolated struct Block: Hashable, Sendable {
        var rounds = 1
        var roundRestSeconds: Double?
        var items: [Item]
    }

    /// The plan as written: circuits stay one block, a rest step stays its own
    /// item. An exercise rests between its own sets — the push encoding
    /// (`GarminWorkoutBuilder`) drops the last set's rest — and then for its
    /// `restAfter`.
    static func blocks(planned steps: [[String: Any]]) -> [Block] {
        steps.indices.compactMap { index in
            let step = steps[index]
            guard let children = step["repeat_steps"] as? [[String: Any]] else {
                return item(step).map { Block(items: [$0] + [restAfter(steps, at: index).map(Item.rest)].compactMap { $0 }) }
            }
            let items = children.compactMap(item)
            guard !items.isEmpty else { return nil }
            return Block(rounds: max(1, Coerce.int(step["repeat_count"]) ?? 1),
                         roundRestSeconds: Coerce.double(step["rest_between_rounds_seconds"]),
                         items: items)
        }
    }

    private static func item(_ step: [String: Any]) -> Item? {
        switch step["type"] as? String {
        case "rest":
            if Coerce.token(step["end_condition"] as? String) == "lap_button" { return .rest(.lapButton) }
            return Coerce.double(step["duration_seconds"]).map { .rest(.timed(seconds: $0)) }
        case "exercise":
            let sets = step["sets"] as? [[String: Any]] ?? []
            guard !sets.isEmpty else { return nil }
            return .exercise(sets.enumerated().map { index, set in
                Line(set: SetRow(exerciseId: step["exercise_id"] as? String,
                                 exerciseName: step["exercise_name"] as? String,
                                 reps: Coerce.int(set["reps"]),
                                 seconds: Coerce.double(set["duration_seconds"]),
                                 weightKg: Coerce.double(set["weight_kg"]),
                                 rest: index < sets.count - 1 ? rest(ofSet: set) : nil))
            })
        default:
            return nil
        }
    }

    /// A planned set's rest: until lap (`rest_until_lap`) or `rest_seconds`.
    static func rest(ofSet set: [String: Any]) -> Rest? {
        set["rest_until_lap"] as? Bool == true ? .lapButton : Coerce.double(set["rest_seconds"]).map { .timed(seconds: $0) }
    }

    /// The rest after the exercise at `index` of a plan's top-level steps:
    /// `rest_after` is `lap_button` (also when absent), `timed`
    /// (`rest_after_seconds`) or `none`. Nil for anything but an exercise, and
    /// when the next step is a rest of its own.
    static func restAfter(_ steps: [[String: Any]], at index: Int) -> Rest? {
        let step = steps[index]
        guard step["type"] as? String == "exercise",
              !(steps.indices.contains(index + 1) && steps[index + 1]["type"] as? String == "rest") else { return nil }
        switch step["rest_after"] as? String ?? "lap_button" {
        case "lap_button": return .lapButton
        case "timed": return Coerce.double(step["rest_after_seconds"]).map { .timed(seconds: $0) }
        default: return nil
        }
    }

    /// A recorded session's `strength.exercises` as rows.
    static func rows(performed entries: [[String: Any]]) -> [SetRow] {
        entries.flatMap { entry in
            (entry["sets"] as? [[String: Any]] ?? []).map { set in
                SetRow(exerciseId: entry["exercise_id"] as? String,
                       exerciseName: entry["exercise_name"] as? String,
                       exerciseCategory: entry["exercise_category"] as? String,
                       reps: Coerce.int(set["reps"]),
                       seconds: Coerce.double(set["duration_seconds"]),
                       weightKg: Coerce.double(set["weight_kg"]),
                       rest: Coerce.double(set["rest_seconds"]).map { .timed(seconds: $0) })
            }
        }
    }

    /// Inverse of `rows(performed:)`: consecutive sets of one exercise regroup
    /// into one stored entry.
    static func entries(_ rows: [SetRow]) -> [[String: Any]] {
        var out: [[String: Any]] = []
        var previous: SetRow?
        for row in rows {
            var set: [String: Any] = [:]
            if let reps = row.reps { set["reps"] = reps }
            if let seconds = row.seconds { set["duration_seconds"] = seconds }
            if let kg = row.weightKg { set["weight_kg"] = kg }
            if let rest = row.restSeconds { set["rest_seconds"] = rest }
            if let previous, previous.sameExercise(as: row) {
                out[out.count - 1]["sets"] = (out[out.count - 1]["sets"] as? [[String: Any]] ?? []) + [set]
            } else {
                var entry: [String: Any] = ["sets": [set]]
                if let id = row.exerciseId { entry["exercise_id"] = id }
                if let name = row.exerciseName { entry["exercise_name"] = name }
                if let category = row.exerciseCategory { entry["exercise_category"] = category }
                out.append(entry)
            }
            previous = row
        }
        return out
    }

    /// Every prescribed set in the order the watch runs them — circuits unrolled
    /// round by round.
    static func plannedSets(_ steps: [[String: Any]]) -> [SetRow] {
        blocks(planned: steps).flatMap { block in
            Array(repeating: block.items.flatMap(\.lines).compactMap(\.set), count: block.rounds).flatMap { $0 }
        }
    }

    /// A recorded session as the coach reads it: one line per exercise, named by
    /// library id where one is known, each set as reps × weight
    /// ("back_squat: 5×60kg, 5×60kg, 4×60kg"). A bodyweight set is its rep count,
    /// a set without one its time ("45s").
    static func coachLines(performed entries: [[String: Any]]) -> [String] {
        var out: [(key: String, sets: [String])] = []
        for row in rows(performed: entries) {
            let key = row.exerciseId ?? row.exerciseName.flatMap { ExerciseLibrary.find(garminName: $0)?.id } ?? row.title
            var set = row.reps.map(String.init) ?? row.seconds.map { "\(Int($0.rounded()))s" } ?? "?"
            if let kg = row.weightKg { set += "×" + String(format: "%g", kg) + "kg" }
            if out.last?.key == key { out[out.count - 1].sets.append(set) } else { out.append((key, [set])) }
        }
        return out.map { "\($0.key): \($0.sets.joined(separator: ", "))" }
    }

    /// A recorded session beside its plan: every recorded set in order, paired
    /// with the prescribed set it matches — each exercise's recorded sets consume
    /// its prescribed sets in order, so interleaved circuit rounds line up — then
    /// every prescribed set nothing was recorded for, after the last line of its
    /// exercise (at the end when the exercise wasn't recorded at all). A paired
    /// set is flagged when the plan prescribed a rep count and the watch counted
    /// a different one, or none.
    static func comparison(planned steps: [[String: Any]], performed: [SetRow]) -> [Line] {
        let prescribed = plannedSets(steps)
        var queues: [String: ArraySlice<Int>] = [:]
        for (index, row) in prescribed.enumerated() {
            if let key = row.garminKey { queues[key, default: []].append(index) }
        }
        var matched = Set<Int>()
        var lines = performed.map { row -> Line in
            guard let key = row.garminKey, let index = queues[key]?.popFirst() else { return Line(set: row) }
            matched.insert(index)
            let plan = prescribed[index]
            return Line(set: row, plan: plan, isFlagged: plan.reps != nil && row.reps != plan.reps)
        }
        for (index, plan) in prescribed.enumerated() where !matched.contains(index) {
            let last = plan.garminKey.flatMap { key in lines.lastIndex { ($0.set ?? $0.plan)?.garminKey == key } }
            lines.insert(Line(plan: plan), at: last.map { $0 + 1 } ?? lines.endIndex)
        }
        return lines
    }
}
