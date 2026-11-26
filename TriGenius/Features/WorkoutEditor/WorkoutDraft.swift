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
    case running, cycling, indoorCycling = "indoor_cycling", swimming, strength, yoga, cardio, other

    var id: String { rawValue }
    var label: String { rawValue.replacingOccurrences(of: "_", with: " ").capitalized }
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
enum RestAfter: String {
    case lapButton = "lap_button", timed, none
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
    /// The target as a share of the athlete's threshold (`PlanResolution`),
    /// in place of `targetLow`/`targetHigh`.
    var targetPercent: Double?
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
    /// The weight is set from the last sessions (`StrengthProgression`).
    var autoLoad = false
    var exerciseRestSeconds = 60
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

    /// A fresh exercise step for `choice`, prescribed as the athlete last did it
    /// (sets, reps or hold time, weight), else 3 × 10 at bodyweight. Its pause
    /// after waits for the lap button in a gym — the next station's wait can't
    /// be known — and runs a minute elsewhere.
    @MainActor
    static func exercise(_ choice: ExerciseChoice) -> StepDraft {
        var step = StepDraft()
        step.isExercise = true
        if let place = StrengthProfile.stored.place, place != .gym {
            step.restAfter = .timed
            step.restAfterSeconds = 60
        }
        step.choose(choice)
        if case .library(let exercise) = choice, case let last = TrainingDataStore.shared.lastLiftedSets(for: exercise),
           let first = last.first {
            step.exerciseSets = min(last.count, 20)
            if let reps = first.reps { step.exerciseReps = reps }
            if exercise.isTimeBased, let seconds = first.seconds { step.exerciseSetSeconds = Int(seconds.rounded()) }
        }
        return step
    }

    /// Point this exercise step at `choice`; a library exercise starts from the
    /// weight the athlete last lifted or planned for it (nil stays bodyweight
    /// rather than inventing a load).
    @MainActor
    mutating func choose(_ choice: ExerciseChoice) {
        switch choice {
        case .library(let exercise):
            exerciseId = exercise.id
            exerciseName = exercise.name
            exerciseIsTimeBased = exercise.isTimeBased
            exerciseWeightKg = TrainingDataStore.shared.startingWeightKg(for: exercise)
        case .custom(let name):
            exerciseId = nil
            exerciseName = name
            exerciseIsTimeBased = false
        }
        autoLoad = canAutoLoad
    }

    /// A library exercise lifted for reps on equipment with weight steps — one
    /// `StrengthProgression` can set the weight of.
    var canAutoLoad: Bool {
        guard !exerciseIsTimeBased, let exercise = exerciseId.flatMap(ExerciseLibrary.find(id:)) else { return false }
        return !StrengthProgression.weightSteps(exercise.equipment).isEmpty
    }

    /// Fit this exercise into a circuit: one set a round, straight on to the
    /// next member.
    mutating func joinCircuit() {
        exerciseSets = 1
        restAfter = .lapButton
    }

    /// The rest between this exercise's sets.
    var setRest: StrengthSets.Rest? {
        get { exerciseRestUntilLap ? .lapButton : .timed(seconds: Double(exerciseRestSeconds)) }
        set {
            exerciseRestUntilLap = newValue == .lapButton
            if case .timed(let seconds) = newValue { exerciseRestSeconds = Int(seconds) }
        }
    }

    /// The pause after this exercise; nil runs straight into the next one.
    var pauseAfter: StrengthSets.Rest? {
        get {
            switch restAfter {
            case .lapButton: return .lapButton
            case .timed: return .timed(seconds: Double(restAfterSeconds))
            case .none: return nil
            }
        }
        set {
            switch newValue {
            case .lapButton: restAfter = .lapButton
            case .timed(let seconds): restAfter = .timed; restAfterSeconds = Int(seconds)
            case nil: restAfter = .none
            }
        }
    }

    /// A circuit's rest between rounds — always timed.
    var roundRest: StrengthSets.Rest? {
        get { .timed(seconds: Double(restBetweenRoundsSeconds)) }
        set { if case .timed(let seconds) = newValue { restBetweenRoundsSeconds = Int(seconds) } }
    }

    /// A rest step's pause (one that follows no exercise, so it stays a step).
    var restStepPause: StrengthSets.Rest? {
        get { end == .lapButton ? .lapButton : .timed(seconds: Double(durationSeconds)) }
        set {
            end = newValue == .lapButton ? .lapButton : .time
            if case .timed(let seconds) = newValue { durationSeconds = Int(seconds) }
        }
    }

    /// Parse a compact step dict. An out-of-schema `type` token (e.g. Garmin's
    /// "other") shows as Interval in the editor — visible before anything is saved.
    init(dict: [String: Any]) {
        if (dict["type"] as? String) == "exercise" {
            isExercise = true
            exerciseId = dict["exercise_id"] as? String
            let sets = dict["sets"] as? [[String: Any]] ?? []
            // Named like `StrengthSets.SetRow.title`: a plan may carry only the id.
            exerciseName = exerciseId.flatMap(ExerciseLibrary.find(id:))?.name ?? dict["exercise_name"] as? String ?? ""
            exerciseIsTimeBased = dict["is_time_based"] as? Bool
                ?? (sets.first.map { $0["reps"] == nil && $0["duration_seconds"] != nil } ?? false)
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
            autoLoad = StrengthProgression.isAuto(dict) && canAutoLoad
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
        targetPercent = Coerce.double(dict["target_percent"])
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
            if autoLoad { d["load"] = "auto" }
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
        if targetType != .noTarget, targetPercent != nil || targetLow != nil || targetHigh != nil {
            d["target_type"] = targetType.rawValue
            if let targetPercent {
                d["target_percent"] = targetPercent
            } else {
                if let targetLow { d["target_low"] = targetLow }
                if let targetHigh { d["target_high"] = targetHigh }
            }
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
    init(date: Date, sport: EditorSport) {
        self.date = Calendar.current.startOfDay(for: date)
        self.sport = sport
    }

    /// Prefill from a `workout_data` dict — a stored plan's or a template's — on
    /// `date`. A strength rest step folds into the exercise before it.
    init(workoutData data: [String: Any], date: Date) {
        name = data["name"] as? String ?? ""
        sport = EditorSport(sportKey: data["sport"] as? String ?? "")
        self.date = Calendar.current.startOfDay(for: date)
        durationMinutes = Coerce.int(data["duration_minutes"]).flatMap { $0 > 0 ? $0 : nil }
        distanceMeters = Coerce.double(data["distance_meters"]).flatMap { $0 > 0 ? $0 : nil }
        poolLength = Coerce.int(data["pool_length"]).flatMap { $0 > 0 ? $0 : nil }
        notes = data["description"] as? String ?? ""
        steps = StrengthSets.foldingRests(data["steps"] as? [[String: Any]] ?? []).map { StepDraft(dict: $0) }
    }

    /// Prefill from a stored plan.
    @MainActor
    init(record: WorkoutRecord) {
        self.init(workoutData: WorkoutPayloadBuilder.workoutData(from: record), date: record.date)
        startMinute = record.startMinute
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
