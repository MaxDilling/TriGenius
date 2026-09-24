import Foundation

// MARK: - Workout editor draft
//
// Value-type form state for the manual workout editor, mapping 1:1 onto the
// compact `workout_data` schema the coach's scheduling tools use. Prefill parses
// a stored plan via `WorkoutPayloadBuilder`; save serializes back to the dict and
// routes through `DataSyncCoordinator.addPlan`/`updatePlan` — the same
// `WorkoutNormalizer` path as the coach, so both authors produce identical plans.
// Every value is held in the raw stored unit (pace seconds, speed km/h, meters,
// seconds); the views convert for display only.

/// The `workout_data.sport` schema enum.
enum EditorSport: String, CaseIterable, Identifiable {
    case running, cycling, swimming, strength, yoga, cardio, other

    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var family: SportFamily { SportFamily(sportKey: rawValue) }

    /// A stored sport key: the exact schema token, else its `SportFamily`
    /// classification (Garmin-mirrored plans use keys like "lap_swimming").
    init(sportKey: String) {
        if let exact = EditorSport(rawValue: sportKey) { self = exact; return }
        switch SportFamily(sportKey: sportKey) {
        case .swim: self = .swimming
        case .bike: self = .cycling
        case .run: self = .running
        case .strength: self = .strength
        case .other: self = .other
        }
    }
}

/// Leaf step types ("repeat" is structural — `StepDraft.isRepeat`).
enum StepKind: String, CaseIterable, Identifiable {
    case warmup, interval, main, recovery, rest, cooldown

    var id: String { rawValue }
    var label: String {
        switch self {
        case .warmup: return "Warm-up"
        case .interval: return "Interval"
        case .main: return "Main"
        case .recovery: return "Recovery"
        case .rest: return "Rest"
        case .cooldown: return "Cool-down"
        }
    }
}

/// A top-level exercise's `rest_after` (`StrengthSets.restAfter`).
enum RestAfter: String, CaseIterable, Identifiable {
    case lapButton = "lap_button", timed, none

    var id: String { rawValue }
    var label: String {
        switch self {
        case .lapButton: return "Until lap"
        case .timed: return "Timed"
        case .none: return "None"
        }
    }
}

enum StepEnd: String, CaseIterable, Identifiable {
    case time, distance, lapButton = "lap_button", fixedRest = "fixed_rest"

    var id: String { rawValue }
    var label: String {
        switch self {
        case .time: return "Time"
        case .distance: return "Distance"
        case .lapButton: return "Lap button"
        case .fixedRest: return "Fixed rest"
        }
    }
}

enum StepTargetType: String, CaseIterable, Identifiable {
    case noTarget = "no_target", heartRate = "heart_rate", power, pace, speed, cadence

    var id: String { rawValue }
    var label: String {
        switch self {
        case .noTarget: return "None"
        case .heartRate: return "Heart rate"
        case .power: return "Power"
        case .pace: return "Pace"
        case .speed: return "Speed"
        case .cadence: return "Cadence"
        }
    }
}

enum SwimStroke: String, CaseIterable, Identifiable {
    case free, breaststroke, backstroke, butterfly, anyStroke = "any_stroke", drill, im

    var id: String { rawValue }
    var label: String {
        switch self {
        case .free: return "Free"
        case .breaststroke: return "Breaststroke"
        case .backstroke: return "Backstroke"
        case .butterfly: return "Butterfly"
        case .anyStroke: return "Any stroke"
        case .drill: return "Drill"
        case .im: return "IM"
        }
    }
}

// MARK: - Step draft

/// One editable step: a leaf, a repeat block over child steps, or an exercise
/// (strength only). Prefill keeps whatever nesting a stored plan carries; the
/// editor only *offers* repeats at the top level (matching the display layer
/// and the Garmin builder).
struct StepDraft: Identifiable {
    let id = UUID()
    var isRepeat = false
    // Leaf fields.
    var kind: StepKind = .interval
    var end: StepEnd = .time
    var durationSeconds = 600
    var distanceMeters: Double = 1000
    var stroke: SwimStroke?
    var targetType: StepTargetType = .noTarget
    /// Raw stored units: pace sec (sec/km, swim sec/100 m), speed km/h, power W,
    /// heart rate bpm, cadence rpm/spm.
    var targetLow: Double?
    var targetHigh: Double?
    // Repeat fields.
    var repeatCount = 4
    var skipLastRest = true
    var children: [StepDraft] = []
    /// Rest between rounds of a strength circuit. Endurance repeat blocks
    /// instead carry rest as an explicit "rest"/"recovery" child step with its
    /// own duration; a circuit's children are all exercises, so this is the
    /// only place that duration can live.
    var restBetweenRoundsSeconds = 60
    // Exercise fields (strength only). The UI is uniform-per-exercise (one
    // reps/weight/rest applied to every set); the stored schema is per-set
    // (`sets: [...]`) so a coach- or Garmin-authored pyramid round-trips
    // without a schema change, even though this editor always writes N
    // identical entries.
    var isExercise = false
    /// Nil for a free-typed custom exercise (not in `ExerciseLibrary`).
    var exerciseId: String?
    var exerciseName = ""
    /// True for holds (plank, wall sit, carries): the editor asks for a
    /// duration per set instead of a rep count.
    var exerciseIsTimeBased = false
    var exerciseSets = 3
    var exerciseReps = 10
    var exerciseSetSeconds = 30
    /// Nil = bodyweight.
    var exerciseWeightKg: Double?
    var exerciseRestSeconds = 90
    var exerciseRestUntilLap = false
    var restAfter: RestAfter = .lapButton
    var restAfterSeconds = 120

    init(isRepeat: Bool = false, kind: StepKind = .interval) {
        self.isRepeat = isRepeat
        self.kind = kind
        if isRepeat {
            children = [StepDraft(kind: .interval), StepDraft(kind: .recovery)]
        }
    }

    /// A fresh exercise step, defaulted to the first library entry the athlete's
    /// `StrengthProfile` allows — or "Custom exercise" when none is available.
    static func exercise() -> StepDraft {
        var step = StepDraft()
        step.isExercise = true
        let profile = StrengthProfile.stored
        if let first = ExerciseLibrary.all.first(where: profile.allows) {
            step.exerciseId = first.id
            step.exerciseName = first.name
            step.exerciseIsTimeBased = first.isTimeBased
        } else {
            step.exerciseName = "Custom exercise"
        }
        return step
    }

    /// A fresh circuit/superset: a repeat block whose children are exercises
    /// rather than the endurance interval/recovery pair `StepDraft(isRepeat:
    /// true)` defaults to.
    static func exerciseCircuit() -> StepDraft {
        var step = StepDraft(isRepeat: true)
        step.children = [StepDraft.exercise(), StepDraft.exercise()]
        return step
    }

    /// A pause between exercises: a plain time-ended rest leaf, the same step an
    /// endurance plan uses.
    static func exerciseRest() -> StepDraft {
        var step = StepDraft(kind: .rest)
        step.durationSeconds = 120
        return step
    }

    /// Parse a compact step dict. An out-of-schema `type` token (e.g. Garmin's
    /// "other") shows as Interval in the editor — visible before anything is saved.
    init(dict: [String: Any]) {
        if (dict["type"] as? String) == "exercise" {
            isExercise = true
            exerciseId = dict["exercise_id"] as? String
            exerciseName = (dict["exercise_name"] as? String) ?? "Exercise"
            exerciseIsTimeBased = dict["is_time_based"] as? Bool ?? false
            let sets = dict["sets"] as? [[String: Any]] ?? []
            exerciseSets = max(1, sets.count)
            // Non-uniform (per-set) prescriptions collapse to the first set's
            // values — this editor only offers a uniform UI; the stepped
            // per-set schema exists for authors that vary sets (not this one).
            if let firstSet = sets.first {
                exerciseReps = Coerce.int(firstSet["reps"]) ?? exerciseReps
                exerciseSetSeconds = Coerce.int(firstSet["duration_seconds"]) ?? exerciseSetSeconds
                exerciseWeightKg = Coerce.double(firstSet["weight_kg"])
                exerciseRestSeconds = Coerce.int(firstSet["rest_seconds"]) ?? exerciseRestSeconds
                exerciseRestUntilLap = firstSet["rest_until_lap"] as? Bool ?? false
            }
            restAfter = (dict["rest_after"] as? String).flatMap(RestAfter.init) ?? .lapButton
            restAfterSeconds = Coerce.int(dict["rest_after_seconds"]) ?? restAfterSeconds
            return
        }
        if let childDicts = dict["repeat_steps"] as? [[String: Any]] {
            isRepeat = true
            repeatCount = Coerce.int(dict["repeat_count"]) ?? 4
            skipLastRest = dict["skip_last_rest"] as? Bool ?? true
            restBetweenRoundsSeconds = Coerce.int(dict["rest_between_rounds_seconds"]) ?? restBetweenRoundsSeconds
            children = childDicts.map { StepDraft(dict: $0) }
            return
        }
        kind = (dict["type"] as? String).flatMap { StepKind(rawValue: Coerce.token($0)) } ?? .interval
        if let s = Coerce.double(dict["duration_seconds"]), s > 0 { durationSeconds = Int(s.rounded()) }
        if let m = Coerce.double(dict["distance_meters"]), m > 0 { distanceMeters = m }
        // Missing end_condition (some provider-mirrored steps): infer from the
        // present extent, mirroring WorkoutNormalizer.endCondition.
        end = (dict["end_condition"] as? String).flatMap { StepEnd(rawValue: Coerce.token($0)) }
            ?? (Coerce.double(dict["distance_meters"]) ?? 0 > 0 ? .distance : .time)
        stroke = (dict["stroke"] as? String).flatMap { SwimStroke(rawValue: Coerce.token($0)) }
        targetType = (dict["target_type"] as? String).flatMap { StepTargetType(rawValue: Coerce.token($0)) } ?? .noTarget
        targetLow = Coerce.double(dict["target_low"])
        targetHigh = Coerce.double(dict["target_high"])
    }

    /// Serialize back to the compact schema. Raw units, no conversion.
    func dict(swim: Bool) -> [String: Any] {
        if isExercise {
            var setDict: [String: Any] = exerciseRestUntilLap ? ["rest_until_lap": true] : ["rest_seconds": exerciseRestSeconds]
            if exerciseIsTimeBased { setDict["duration_seconds"] = exerciseSetSeconds } else { setDict["reps"] = exerciseReps }
            if let exerciseWeightKg { setDict["weight_kg"] = exerciseWeightKg }
            var d: [String: Any] = [
                "type": "exercise",
                "exercise_name": exerciseName,
                "is_time_based": exerciseIsTimeBased,
                "sets": Array(repeating: setDict, count: max(1, exerciseSets)),
            ]
            if let exerciseId { d["exercise_id"] = exerciseId }
            if restAfter != .lapButton { d["rest_after"] = restAfter.rawValue }
            if restAfter == .timed { d["rest_after_seconds"] = restAfterSeconds }
            return d
        }
        if isRepeat {
            var d: [String: Any] = [
                "type": "repeat",
                "repeat_count": repeatCount,
                "skip_last_rest": skipLastRest,
                "repeat_steps": children.map { $0.dict(swim: swim) },
            ]
            // Exercise children have no rest-kind sibling step the way
            // endurance repeat blocks do, so a circuit's between-round rest
            // has nowhere else to live.
            if children.contains(where: { $0.isExercise }) {
                d["rest_between_rounds_seconds"] = restBetweenRoundsSeconds
            }
            return d
        }
        var d: [String: Any] = ["type": kind.rawValue, "end_condition": end.rawValue]
        switch end {
        case .distance: d["distance_meters"] = distanceMeters
        case .time, .fixedRest: d["duration_seconds"] = durationSeconds
        case .lapButton: break
        }
        if swim, let stroke { d["stroke"] = stroke.rawValue }
        if targetType != .noTarget, targetLow != nil || targetHigh != nil {
            d["target_type"] = targetType.rawValue
            if let targetLow { d["target_low"] = targetLow }
            if let targetHigh { d["target_high"] = targetHigh }
        }
        return d
    }
}

// MARK: - Workout draft

struct WorkoutDraft {
    var name = ""
    var sport: EditorSport = .running
    var date: Date
    var startMinute: Int?
    var durationMinutes: Int?
    var distanceMeters: Double?
    var poolLength: Int?
    var notes = ""
    var steps: [StepDraft] = []

    /// A fresh plan on `date`.
    init(date: Date) {
        self.date = Calendar.current.startOfDay(for: date)
    }

    /// Prefill from a stored plan.
    @MainActor
    init(record: WorkoutRecord) {
        name = record.name
        sport = EditorSport(sportKey: record.sport)
        date = record.date
        startMinute = record.startMinute
        durationMinutes = record.targetDurationMinutes > 0 ? Int(record.targetDurationMinutes.rounded()) : nil
        distanceMeters = record.targetDistanceMeters > 0 ? record.targetDistanceMeters : nil
        poolLength = record.poolLengthMeters.flatMap { $0 > 0 ? Int($0.rounded()) : nil }
        notes = record.notes
        steps = (WorkoutPayloadBuilder.parseSteps(record.stepsJSON) ?? []).map { StepDraft(dict: $0) }
    }

    /// Serialize to the compact `workout_data` dict. The editor is a full-state
    /// form, so `steps` is always sent — an emptied list deliberately hands the
    /// normalizer an empty array, which re-synthesizes the structure from the
    /// duration/distance goal (same as the coach path).
    func workoutData() -> [String: Any] {
        var d: [String: Any] = ["name": name, "sport": sport.rawValue]
        if let durationMinutes, durationMinutes > 0 { d["duration_minutes"] = durationMinutes }
        if let distanceMeters, distanceMeters > 0 { d["distance_meters"] = distanceMeters }
        if sport == .swimming, let poolLength, poolLength > 0 { d["pool_length"] = poolLength }
        if !notes.isEmpty { d["description"] = notes }
        d["steps"] = steps.map { $0.dict(swim: sport == .swimming) }
        return d
    }
}
