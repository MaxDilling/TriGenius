import Foundation

// MARK: - Strength profile (handoff flow 7)
//
// The facts the strength side is set up from: where the athlete trains, which
// fixes the equipment, and the areas to work around. An area excludes every
// exercise loading its tissue group, as a primary or a secondary mover —
// exclusion only, no medical logic (D10). Experience is the `strength` sport
// profile's level (`Experience`). Stored on that profile (`CoachMemory`); the
// exercise picker, `get_exercises` and the coach prompt all apply it.

nonisolated struct StrengthProfile: Hashable, Sendable {

    nonisolated enum Place: String, CaseIterable, Sendable {
        case gym, homeWeights = "home_weights", bodyweight

        var label: String {
            switch self {
            case .gym: return "Gym"
            case .homeWeights: return "Home with weights"
            case .bodyweight: return "Bodyweight only"
            }
        }

        var equipment: Set<Exercise.Equipment> {
            switch self {
            case .gym: return Set(Exercise.Equipment.allCases)
            case .homeWeights: return [.dumbbell, .kettlebell, .band, .bodyweight]
            case .bodyweight: return [.bodyweight]
            }
        }
    }

    nonisolated enum Area: String, CaseIterable, Sendable {
        case achilles, knee, lowBack = "low_back", shoulder

        var label: String {
            switch self {
            case .achilles: return "Achilles"
            case .knee: return "Knee"
            case .lowBack: return "Low back"
            case .shoulder: return "Shoulder"
            }
        }

        var group: TissueGroup {
            switch self {
            case .achilles: return .calves
            case .knee: return .quads
            case .lowBack: return .lowBack
            case .shoulder: return .shoulders
            }
        }
    }

    /// Stored as the sport profile's level — the value `update_sport_profile`
    /// documents, so the coach and the setup screen write the same words.
    nonisolated enum Experience: String, CaseIterable, Sendable {
        case beginner, intermediate, advanced

        var label: String {
            switch self {
            case .beginner: return "New to lifting"
            case .intermediate: return "Some experience"
            case .advanced: return "Lift regularly"
            }
        }
    }

    /// Nil until set up: every piece of equipment is allowed.
    var place: Place?
    var excludedAreas: Set<Area> = []

    func allows(_ exercise: Exercise) -> Bool {
        let loaded = Set(exercise.primaryGroups + exercise.secondaryGroups)
        return (place?.equipment.contains(exercise.equipment) ?? true)
            && !excludedAreas.contains { loaded.contains($0.group) }
    }

    /// "trains at: home with weights; works around: knee, shoulder" — nil when
    /// nothing is set.
    var summary: String? {
        var parts: [String] = []
        if let place { parts.append("trains at: \(place.label.lowercased())") }
        if !excludedAreas.isEmpty {
            let areas = Area.allCases.filter(excludedAreas.contains).map { $0.label.lowercased() }
            parts.append("works around: \(areas.joined(separator: ", "))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "; ")
    }
}
