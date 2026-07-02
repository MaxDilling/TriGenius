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

/// One editable step: a leaf, or a repeat block over child steps. Prefill keeps
/// whatever nesting a stored plan carries; the editor only *offers* repeats at the
/// top level (matching the display layer and the Garmin builder).
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

    init(isRepeat: Bool = false, kind: StepKind = .interval) {
        self.isRepeat = isRepeat
        self.kind = kind
        if isRepeat {
            children = [StepDraft(kind: .interval), StepDraft(kind: .recovery)]
        }
    }

    /// Parse a compact step dict. An out-of-schema `type` token (e.g. Garmin's
    /// "other") shows as Interval in the editor — visible before anything is saved.
    init(dict: [String: Any]) {
        if let childDicts = dict["repeat_steps"] as? [[String: Any]] {
            isRepeat = true
            repeatCount = Coerce.int(dict["repeat_count"]) ?? 4
            skipLastRest = dict["skip_last_rest"] as? Bool ?? true
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
        if isRepeat {
            return [
                "type": "repeat",
                "repeat_count": repeatCount,
                "skip_last_rest": skipLastRest,
                "repeat_steps": children.map { $0.dict(swim: swim) },
            ]
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
