import Foundation

// MARK: - Garmin's muscle map
//
// The primary/secondary muscles Garmin's own exercise catalog assigns to each of its
// ~1500 exercises (`Assets/Exercises/garmin-muscles.json`, trimmed from
// `ref/garmin_api/exercises/Exercises.json`), keyed by category + name because 26
// names repeat across categories. It is the single source of an exercise's tissue
// groups: `ExerciseLibrary` resolves its entries through it, and a recorded set of
// an exercise outside the library still gets groups.
//
// Every one of Garmin's 17 muscles folds onto a group. The front of the trunk (abs,
// obliques) counts as Low back — the group that replaces "Core / low back" — and the
// chest as Shoulders, the joint a press loads. Garmin names no shin muscle.

nonisolated enum GarminMuscle: String, CaseIterable, Sendable {
    case calves = "CALVES", hamstrings = "HAMSTRINGS", quads = "QUADS", glutes = "GLUTES",
         abductors = "ABDUCTORS", hips = "HIPS", adductors = "ADDUCTORS", lowerBack = "LOWER_BACK",
         abs = "ABS", obliques = "OBLIQUES", lats = "LATS", traps = "TRAPS", shoulders = "SHOULDERS",
         chest = "CHEST", biceps = "BICEPS", triceps = "TRICEPS", forearm = "FOREARM"

    var group: TissueGroup {
        switch self {
        case .calves: return .calves
        case .hamstrings: return .hamstrings
        case .quads: return .quads
        case .glutes, .abductors: return .glutes
        case .hips: return .hipFlexors
        case .adductors: return .adductors
        case .lowerBack, .abs, .obliques: return .lowBack
        case .lats, .traps: return .upperBack
        case .shoulders, .chest: return .shoulders
        case .biceps: return .biceps
        case .triceps: return .triceps
        case .forearm: return .forearms
        }
    }
}

nonisolated enum GarminMuscles {

    static func muscles(category: String, name: String) -> (primary: [GarminMuscle], secondary: [GarminMuscle])? {
        guard let muscles = catalog[category]?[name], muscles.count == 2 else { return nil }
        return (muscles[0].compactMap(GarminMuscle.init), muscles[1].compactMap(GarminMuscle.init))
    }

    static func groups(category: String, name: String) -> (primary: [TissueGroup], secondary: [TissueGroup])? {
        guard let muscles = muscles(category: category, name: name) else { return nil }
        let primary = unique(muscles.primary.map(\.group))
        return (primary, unique(muscles.secondary.map(\.group)).filter { !primary.contains($0) })
    }

    private static func unique(_ groups: [TissueGroup]) -> [TissueGroup] {
        groups.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }

    private static let catalog: [String: [String: [[String]]]] = {
        guard let url = Bundle.main.url(forResource: "garmin-muscles", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: [String: [[String]]]].self, from: data)
        else { return [:] }
        return decoded
    }()
}

/// The muscles an exercise's animation colours, by Garmin's names — finer than the
/// tissue groups, so a press shows the chest and a raise the shoulders. An exercise
/// Garmin's catalog lacks gets every muscle folding onto its own groups.
nonisolated struct ExerciseMuscles: Sendable {
    var primary: Set<GarminMuscle>
    var secondary: Set<GarminMuscle>

    init(_ exercise: Exercise) {
        if let category = exercise.garminCategory, let name = exercise.garminName,
           let muscles = GarminMuscles.muscles(category: category, name: name) {
            primary = Set(muscles.primary)
            secondary = Set(muscles.secondary)
        } else {
            let folding = { (groups: [TissueGroup]) in Set(GarminMuscle.allCases.filter { groups.contains($0.group) }) }
            primary = folding(exercise.primaryGroups)
            secondary = folding(exercise.secondaryGroups)
        }
    }

    /// The strongest role among `muscles`: 2 primary, 1 secondary, 0 neither.
    func level(_ muscles: [GarminMuscle]) -> Int {
        muscles.map { primary.contains($0) ? 2 : secondary.contains($0) ? 1 : 0 }.max() ?? 0
    }
}
