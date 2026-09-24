import Foundation

// MARK: - Exercise library
//
// ~60 curated strength exercises (Tissue Load handoff decision D8), each with
// the tissue groups it loads — from Garmin's catalog (`GarminMuscles`), or its
// own list for the few Garmin lacks — and whether it loads a tendon. Bundled as
// JSON rather than Assets/Knowledge/ prose: this is picker data the workout
// editor reads directly, not something the model reasons over. A step's
// exercise is free to reference none of these (a custom/typed name); an
// unmapped exercise contributes nothing to the tissue forecast.

nonisolated struct Exercise: Codable, Identifiable, Hashable, Sendable {
    nonisolated enum Category: String, Codable, CaseIterable, Hashable, Sendable {
        case compound, isolation, core, carry, plyometric, isometric

        var label: String {
            switch self {
            case .compound: return "Compound"
            case .isolation: return "Isolation"
            case .core: return "Core"
            case .carry: return "Carry"
            case .plyometric: return "Plyometric"
            case .isometric: return "Isometric"
            }
        }
    }

    nonisolated enum Equipment: String, Codable, CaseIterable, Sendable {
        case barbell, dumbbell, kettlebell, machine, cable, band, bodyweight

        var label: String { rawValue.capitalized }
    }

    var id: String
    var name: String
    var category: Category
    var equipment: Equipment
    /// True for holds (plank, wall sit, carries) — the editor asks for a
    /// duration per set instead of a rep count.
    var isTimeBased: Bool
    /// From Garmin's catalog (`GarminMuscles`) whenever the exercise has an entry
    /// there; only the few it lacks carry their own groups in the JSON.
    var primaryGroups: [TissueGroup]
    var secondaryGroups: [TissueGroup]
    var loadsTendon: Bool
    /// The matching entry in Garmin's own exercise catalog
    /// (`ref/garmin_api/exercises/Exercises.json`), so a pushed strength workout
    /// names the movement on the watch. Nil for the handful Garmin has no entry
    /// for — those steps go over unnamed rather than as a neighbouring exercise.
    var garminCategory: String?
    var garminName: String?

    enum CodingKeys: String, CodingKey {
        case id, name, category, equipment
        case isTimeBased = "is_time_based"
        case primaryGroups = "primary_groups"
        case secondaryGroups = "secondary_groups"
        case loadsTendon = "loads_tendon"
        case garminCategory = "garmin_category"
        case garminName = "garmin_name"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        category = try c.decode(Category.self, forKey: .category)
        equipment = try c.decode(Equipment.self, forKey: .equipment)
        isTimeBased = try c.decode(Bool.self, forKey: .isTimeBased)
        loadsTendon = try c.decode(Bool.self, forKey: .loadsTendon)
        garminCategory = try c.decodeIfPresent(String.self, forKey: .garminCategory)
        garminName = try c.decodeIfPresent(String.self, forKey: .garminName)
        if let garminCategory, let garminName,
           let groups = GarminMuscles.groups(category: garminCategory, name: garminName) {
            primaryGroups = groups.primary
            secondaryGroups = groups.secondary
        } else {
            primaryGroups = try c.decodeIfPresent([TissueGroup].self, forKey: .primaryGroups) ?? []
            secondaryGroups = try c.decodeIfPresent([TissueGroup].self, forKey: .secondaryGroups) ?? []
        }
    }
}

nonisolated enum ExerciseLibrary {
    /// All curated exercises, loaded once from the bundled JSON. Empty (never
    /// traps) if the resource is missing — the editor's picker falls back to
    /// "Custom" only.
    static let all: [Exercise] = load()

    static func find(id: String) -> Exercise? {
        all.first { $0.id == id }
    }

    /// The exercise Garmin's key names, when exactly one carries it (two leg
    /// curls share `LEG_CURL`, and naming either would be a guess).
    static func find(garminName: String) -> Exercise? {
        let matches = all.filter { $0.garminName == garminName }
        return matches.count == 1 ? matches[0] : nil
    }

    private static func load() -> [Exercise] {
        guard let url = Bundle.main.url(forResource: "exercise-library", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let exercises = try? JSONDecoder().decode([Exercise].self, from: data) else { return [] }
        return exercises
    }
}
