import Foundation

// MARK: - Garmin Lookup Tables
//
// Ported from TriGenius_python/mappings.py — the Garmin-specific subset used by
// the service and workout-builder layers.

nonisolated enum GarminMappings {

    /// Garmin activityType id → coarse sport label.
    static let activityTypeToSport: [Int: String] = [
        1: "running", 2: "cycling", 3: "hiking", 4: "other", 5: "swimming",
        6: "walking", 7: "other", 8: "indoor_cycling", 9: "strength_training",
        10: "cardio", 11: "indoor_rowing", 12: "elliptical", 13: "stair_climbing",
        15: "yoga", 17: "running", 25: "cycling", 26: "swimming", 27: "swimming",
        29: "trail_running", 37: "virtual_cycling", 60: "other", 89: "running"
    ]

    /// Coach-facing sport name → Garmin sportTypeId set used to filter activities.
    static let sportFilterIDs: [String: [Int]] = [
        "running": [1, 17, 29, 89],
        "cycling": [2, 25, 37],
        "swimming": [5, 26, 27],
        "strength": [9, 10],
        "gym": [9, 10],
        "hiking": [3],
        "walking": [6]
    ]

    struct SportType { let sportTypeId: Int; let sportTypeKey: String; let displayOrder: Int
        var dict: [String: Any] { ["sportTypeId": sportTypeId, "sportTypeKey": sportTypeKey, "displayOrder": displayOrder] }
    }

    static let workoutSportTypes: [String: SportType] = [
        "running": SportType(sportTypeId: 1, sportTypeKey: "running", displayOrder: 1),
        "run": SportType(sportTypeId: 1, sportTypeKey: "running", displayOrder: 1),
        "trail_running": SportType(sportTypeId: 1, sportTypeKey: "running", displayOrder: 1),
        "treadmill": SportType(sportTypeId: 1, sportTypeKey: "running", displayOrder: 1),
        "cycling": SportType(sportTypeId: 2, sportTypeKey: "cycling", displayOrder: 2),
        "bike": SportType(sportTypeId: 2, sportTypeKey: "cycling", displayOrder: 2),
        "biking": SportType(sportTypeId: 2, sportTypeKey: "cycling", displayOrder: 2),
        "indoor_cycling": SportType(sportTypeId: 2, sportTypeKey: "cycling", displayOrder: 2),
        "swimming": SportType(sportTypeId: 4, sportTypeKey: "swimming", displayOrder: 3),
        "swim": SportType(sportTypeId: 4, sportTypeKey: "swimming", displayOrder: 3),
        "pool_swimming": SportType(sportTypeId: 4, sportTypeKey: "swimming", displayOrder: 3),
        "lap_swimming": SportType(sportTypeId: 4, sportTypeKey: "swimming", displayOrder: 3),
        "open_water": SportType(sportTypeId: 4, sportTypeKey: "swimming", displayOrder: 3),
        "strength": SportType(sportTypeId: 5, sportTypeKey: "strength_training", displayOrder: 4),
        "strength_training": SportType(sportTypeId: 5, sportTypeKey: "strength_training", displayOrder: 4),
        "gym": SportType(sportTypeId: 5, sportTypeKey: "strength_training", displayOrder: 4),
        "weight_training": SportType(sportTypeId: 5, sportTypeKey: "strength_training", displayOrder: 4),
        "cardio": SportType(sportTypeId: 6, sportTypeKey: "cardio_training", displayOrder: 5),
        "cardio_training": SportType(sportTypeId: 6, sportTypeKey: "cardio_training", displayOrder: 5),
        "yoga": SportType(sportTypeId: 10, sportTypeKey: "yoga", displayOrder: 6),
        "other": SportType(sportTypeId: 0, sportTypeKey: "other", displayOrder: 99)
    ]

    /// Garmin swimStroke (string or int code) → normalized stroke name.
    static let swimStrokesByName: [String: String] = [
        "ANY": "any_stroke", "FREESTYLE": "freestyle", "BACKSTROKE": "backstroke",
        "BREASTSTROKE": "breaststroke", "BUTTERFLY": "butterfly", "DRILL": "drill", "MIXED": "mixed"
    ]
    static let swimStrokesByCode: [Int: String] = [
        0: "any_stroke", 1: "freestyle", 2: "backstroke", 3: "breaststroke",
        4: "butterfly", 5: "drill", 6: "mixed"
    ]

    struct StepType { let id: Int; let key: String
        var dict: [String: Any] { ["stepTypeId": id, "stepTypeKey": key] }
    }
    static let workoutStepTypes: [String: StepType] = [
        "warmup": StepType(id: 1, key: "warmup"),
        "warm-up": StepType(id: 1, key: "warmup"),
        "warm_up": StepType(id: 1, key: "warmup"),
        "cooldown": StepType(id: 2, key: "cooldown"),
        "cool-down": StepType(id: 2, key: "cooldown"),
        "cool_down": StepType(id: 2, key: "cooldown"),
        "interval": StepType(id: 3, key: "interval"),
        "work": StepType(id: 3, key: "interval"),
        "recovery": StepType(id: 4, key: "recovery"),
        "rest": StepType(id: 5, key: "rest"),
        "repeat": StepType(id: 6, key: "repeat"),
        "main": StepType(id: 8, key: "main")
    ]

    nonisolated(unsafe) static let workoutEndConditions: [String: [String: Any]] = [
        "time": ["conditionTypeId": 2, "conditionTypeKey": "time", "displayOrder": 2, "displayable": true],
        "distance": ["conditionTypeId": 3, "conditionTypeKey": "distance", "displayOrder": 3, "displayable": true],
        "lap_button": ["conditionTypeId": 1, "conditionTypeKey": "lap.button", "displayOrder": 1, "displayable": true],
        "lap.button": ["conditionTypeId": 1, "conditionTypeKey": "lap.button", "displayOrder": 1, "displayable": true],
        "fixed_rest": ["conditionTypeId": 8, "conditionTypeKey": "fixed.rest", "displayOrder": 8, "displayable": true],
        "fixed.rest": ["conditionTypeId": 8, "conditionTypeKey": "fixed.rest", "displayOrder": 8, "displayable": true]
    ]

    nonisolated(unsafe) static let workoutStrokes: [String: [String: Any]] = [
        "free": ["strokeTypeId": 6, "strokeTypeKey": "free", "displayOrder": 6],
        "freestyle": ["strokeTypeId": 6, "strokeTypeKey": "free", "displayOrder": 6],
        "breaststroke": ["strokeTypeId": 3, "strokeTypeKey": "breaststroke", "displayOrder": 3],
        "breast": ["strokeTypeId": 3, "strokeTypeKey": "breaststroke", "displayOrder": 3],
        "backstroke": ["strokeTypeId": 2, "strokeTypeKey": "backstroke", "displayOrder": 2],
        "back": ["strokeTypeId": 2, "strokeTypeKey": "backstroke", "displayOrder": 2],
        "butterfly": ["strokeTypeId": 4, "strokeTypeKey": "butterfly", "displayOrder": 4],
        "fly": ["strokeTypeId": 4, "strokeTypeKey": "butterfly", "displayOrder": 4],
        "any_stroke": ["strokeTypeId": 1, "strokeTypeKey": "any_stroke", "displayOrder": 1],
        "any": ["strokeTypeId": 1, "strokeTypeKey": "any_stroke", "displayOrder": 1],
        "mixed": ["strokeTypeId": 1, "strokeTypeKey": "any_stroke", "displayOrder": 1],
        "im": ["strokeTypeId": 5, "strokeTypeKey": "im", "displayOrder": 5],
        "drill": ["strokeTypeId": 7, "strokeTypeKey": "drill", "displayOrder": 7]
    ]
    /// Stroke payload for steps with no stroke (e.g. rest).
    nonisolated(unsafe) static let workoutStrokeNone: [String: Any] = ["strokeTypeId": 0, "strokeTypeKey": NSNull(), "displayOrder": 0]

    nonisolated(unsafe) static let workoutTargetTypes: [String: [String: Any]] = [
        "no_target": ["workoutTargetTypeId": 1, "workoutTargetTypeKey": "no.target", "displayOrder": 1],
        "heart_rate": ["workoutTargetTypeId": 4, "workoutTargetTypeKey": "heart.rate.zone", "displayOrder": 4],
        "power": ["workoutTargetTypeId": 2, "workoutTargetTypeKey": "power.zone", "displayOrder": 2],
        "pace": ["workoutTargetTypeId": 6, "workoutTargetTypeKey": "pace.zone", "displayOrder": 6],
        "speed": ["workoutTargetTypeId": 5, "workoutTargetTypeKey": "speed.zone", "displayOrder": 5],
        "cadence": ["workoutTargetTypeId": 3, "workoutTargetTypeKey": "cadence.zone", "displayOrder": 3]
    ]
}
