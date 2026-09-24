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

nonisolated enum GarminMuscles {

    static func groups(category: String, name: String) -> (primary: [TissueGroup], secondary: [TissueGroup])? {
        guard let muscles = catalog[category]?[name], muscles.count == 2 else { return nil }
        let primary = unique(muscles[0].compactMap(group))
        return (primary, unique(muscles[1].compactMap(group)).filter { !primary.contains($0) })
    }

    private static func group(_ muscle: String) -> TissueGroup? {
        switch muscle {
        case "CALVES": return .calves
        case "HAMSTRINGS": return .hamstrings
        case "QUADS": return .quads
        case "GLUTES", "ABDUCTORS": return .glutes
        case "HIPS": return .hipFlexors
        case "ADDUCTORS": return .adductors
        case "LOWER_BACK", "ABS", "OBLIQUES": return .lowBack
        case "LATS", "TRAPS": return .upperBack
        case "SHOULDERS", "CHEST": return .shoulders
        case "BICEPS": return .biceps
        case "TRICEPS": return .triceps
        case "FOREARM": return .forearms
        default: return nil
        }
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
