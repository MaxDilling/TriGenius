import Foundation

// MARK: - Sport Family
//
// Source-agnostic classification of an activity's sport. Garmin and HealthKit
// report sport keys with different spellings ("lap_swimming" vs "Swimming",
// "Cycling" vs "road_biking"); this collapses them into the families the
// dashboard and analytics care about. Single source of truth for sport matching
// — both `DataSyncCoordinator` (filtering) and the analytics layer use it.

nonisolated enum SportFamily: String, CaseIterable, Identifiable, Sendable {
    case swim
    case bike
    case run
    case strength
    case other

    var id: String { rawValue }

    /// The triathlon disciplines, in display order (Swim → Bike → Run).
    static let triathlon: [SportFamily] = [.swim, .bike, .run]

    var displayName: String {
        switch self {
        case .swim: return "Swim"
        case .bike: return "Bike"
        case .run: return "Run"
        case .strength: return "Strength"
        case .other: return "Other"
        }
    }

    /// Classify a source-reported sport key into a family.
    init(sportKey: String) {
        let s = sportKey.lowercased()
        if s.contains("swim") { self = .swim }
        else if s.contains("cycl") || s.contains("ride") || s.contains("bik") { self = .bike }
        else if s.contains("run") { self = .run }
        else if s.contains("strength") || s.contains("gym") { self = .strength }
        else { self = .other }
    }

    /// Whether a stored sport key matches a free-text filter (e.g. the coach
    /// asking for "swimming"). Tolerant of source naming differences.
    static func matches(storedSport stored: String, filter: String) -> Bool {
        let f = filter.lowercased()
        switch f {
        case "running": return SportFamily(sportKey: stored) == .run
        case "cycling": return SportFamily(sportKey: stored) == .bike
        case "swimming": return SportFamily(sportKey: stored) == .swim
        case "strength", "gym": return SportFamily(sportKey: stored) == .strength
        case "hiking": return stored.lowercased().contains("hik")
        case "walking": return stored.lowercased().contains("walk")
        default: return stored.lowercased().contains(f)
        }
    }
}
