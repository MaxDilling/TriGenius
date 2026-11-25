import Foundation

// MARK: - Strength progression: an auto-load exercise's weight from its last sessions
//
// An exercise step marked `"load": "auto"` takes its weight from what the
// athlete did on it lately; a fixed one keeps its own.
//
// Whether the weight changes is judged set by set against the prescribed reps T
// and the set's rating (`StrengthSets.Effort`): too light at T+2 or more, or at
// T…T+1 rated easy; too heavy at T−3 or fewer unless rated easy; anything else
// fits. A session leans the way most of its sets do (too light only once every
// prescribed set was done). The weight changes when the last two sessions (or
// the only one) lean the same way, or at once when the latest is far off —
// most sets at T+4 or more, or T−4 or fewer. A latest session rated RPE 9+
// holds an increase back. Otherwise it is the weight lifted last time.
//
// How far it moves comes from an estimated one-rep max (Epley, with the reps
// in reserve the rating implies): the weight for T reps at a "right" effort,
// rounded to the equipment's step, at least one step. The step grows with the
// weight — the largest of the equipment's steps within 7.5 % of it, so a 60 kg
// barbell moves by 2.5 and a 140 kg leg press by 10. The result is a planned
// value, never a measurement.

nonisolated enum StrengthProgression {

    /// An exercise's sets in one recorded session, and that session's RPE.
    nonisolated struct Session: Sendable {
        var sets: [StrengthSets.SetRow]
        var rpe: Int?
    }

    static let holdingRPE = 9
    static let sessionsConsidered = 2

    /// The weight changes the equipment allows, smallest first; empty when it carries none.
    static func weightSteps(_ equipment: Exercise.Equipment) -> [Double] {
        switch equipment {
        case .barbell, .machine, .cable: [2.5, 5, 10]
        case .dumbbell: [2]
        case .kettlebell: [4]
        case .band, .bodyweight: []
        }
    }

    /// The largest of `steps` within 7.5 % of `kg`, at least the smallest.
    static func step(at kg: Double, _ steps: [Double]) -> Double {
        steps.last { $0 <= kg * 0.075 } ?? steps[0]
    }

    /// Whether a step's weight is set from the last sessions.
    static func isAuto(_ step: [String: Any]) -> Bool { step["load"] as? String == "auto" }

    /// The keys (`SetRow.garminKey`) of every auto-load exercise, circuits included.
    static func autoKeys(_ steps: [[String: Any]]) -> Set<String> {
        steps.reduce(into: []) { keys, step in
            if let children = step["repeat_steps"] as? [[String: Any]] { keys.formUnion(autoKeys(children)) }
            if isAuto(step), let key = key(step) { keys.insert(key) }
        }
    }

    /// The steps with every auto-load exercise's weight set from its recorded
    /// sessions (`recent`, latest first, by key). A pyramid keeps its shape —
    /// every weighted set moves by the same amount; a step without a weight
    /// takes the new one on every set. An exercise never recorded keeps its own.
    static func progressing(_ steps: [[String: Any]], recent: (String) -> [Session]) -> [[String: Any]] {
        let auto = autoKeys(steps)
        var prescribed: [String: [StrengthSets.SetRow]] = [:]
        for row in StrengthSets.plannedSets(steps) {
            if let key = row.garminKey, auto.contains(key) { prescribed[key, default: []].append(row) }
        }
        var weights: [String: (from: Double?, to: Double)] = [:]
        for (key, targets) in prescribed {
            if let to = weight(targets, Array(recent(key).prefix(sessionsConsidered))) {
                weights[key] = (targets.compactMap(\.weightKg).max(), to)
            }
        }
        return applying(weights, to: steps)
    }

    // MARK: The rule

    private enum Lean { case light, heavy, fits }

    private static func lean(target: Int, done: Int?, effort: StrengthSets.Effort?) -> Lean {
        guard let done else { return .fits }
        if done >= target + 2 || (done >= target && effort == .easy) { return .light }
        if done <= target - 3 && effort != .easy { return .heavy }
        return .fits
    }

    /// The way most sets lean, and whether most of them are far off.
    private static func lean(_ targets: [Int], _ session: Session) -> (lean: Lean, far: Bool) {
        let pairs = Array(zip(targets, session.sets))
        let leans = pairs.map { lean(target: $0, done: $1.reps, effort: $1.effort) }
        let majority = targets.count / 2 + 1
        if leans.filter({ $0 == .light }).count >= majority, session.sets.count >= targets.count {
            return (.light, pairs.filter { target, set in set.reps.map { $0 >= target + 4 } ?? false }.count >= majority)
        }
        if leans.filter({ $0 == .heavy }).count >= majority {
            return (.heavy, pairs.filter { target, set in set.reps.map { $0 <= target - 4 } ?? false }.count >= majority)
        }
        return (.fits, false)
    }

    /// The next session's weight; nil when there is no session to go by, no
    /// step to move in, or a prescription without reps.
    private static func weight(_ targets: [StrengthSets.SetRow], _ sessions: [Session]) -> Double? {
        let reps = targets.compactMap(\.reps)
        guard let exercise = targets[0].exerciseId.flatMap(ExerciseLibrary.find(id:)),
              case let steps = weightSteps(exercise.equipment), !steps.isEmpty,
              reps.count == targets.count,
              let latest = sessions.first,
              let lastKg = latest.sets.compactMap(\.weightKg).max() else { return nil }
        let leans = sessions.map { lean(reps, $0) }
        let agree = leans.allSatisfy { $0.lean == leans[0].lean }
        let step = step(at: lastKg, steps)
        let targetReps = Double(reps.sorted()[reps.count / 2])
        let estimate = (oneRepMax(latest) / (1 + (targetReps + rir(nil)) / 30) / step).rounded() * step
        switch leans[0].far || agree ? leans[0].lean : .fits {
        case .light:
            if let rpe = latest.rpe, rpe >= holdingRPE { return lastKg }
            return max(lastKg + step, estimate)
        case .heavy:
            return max(steps[0], min(lastKg - step, estimate))
        case .fits:
            return lastKg
        }
    }

    /// Reps in reserve a rating implies; an unrated set counts as "right".
    private static func rir(_ effort: StrengthSets.Effort?) -> Double {
        switch effort {
        case .easy: 3
        case .hard: 0
        case .right, nil: 1.5
        }
    }

    /// The median Epley estimate over the session's weighted, counted sets.
    private static func oneRepMax(_ session: Session) -> Double {
        let estimates = session.sets.compactMap { set -> Double? in
            guard let kg = set.weightKg, let reps = set.reps else { return nil }
            return kg * (1 + (Double(reps) + rir(set.effort)) / 30)
        }.sorted()
        return estimates.isEmpty ? 0 : estimates[estimates.count / 2]
    }

    // MARK: Steps

    private static func key(_ step: [String: Any]) -> String? {
        StrengthSets.SetRow(exerciseId: step["exercise_id"] as? String,
                            exerciseName: step["exercise_name"] as? String,
                            exerciseCategory: step["exercise_category"] as? String).garminKey
    }

    private static func applying(_ weights: [String: (from: Double?, to: Double)], to steps: [[String: Any]]) -> [[String: Any]] {
        steps.map { step in
            var step = step
            if let children = step["repeat_steps"] as? [[String: Any]] {
                step["repeat_steps"] = applying(weights, to: children)
                return step
            }
            guard isAuto(step), let weight = key(step).flatMap({ weights[$0] }),
                  let sets = step["sets"] as? [[String: Any]] else { return step }
            step["sets"] = sets.map { set in
                var set = set
                if let from = weight.from {
                    if let kg = Coerce.double(set["weight_kg"]) { set["weight_kg"] = max(0, kg + weight.to - from) }
                } else {
                    set["weight_kg"] = weight.to
                }
                return set
            }
            return step
        }
    }
}
