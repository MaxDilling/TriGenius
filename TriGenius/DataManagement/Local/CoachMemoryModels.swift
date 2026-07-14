import Foundation
import SwiftData

// MARK: - Coach-memory SwiftData models
//
// The athlete's prompt context (formerly coach_memory.json) lives in the same
// SwiftData store as the time-series, so it rides the one CloudKit sync.
// Decomposed into rows rather than a single blob so a multi-device merge keeps
// both sides: feedback added on two devices both survive; per-sport progress
// merges per sport. `CoachMemory` is the façade that assembles these rows back
// into the value structs the rest of the app already consumes.
//
// CloudKit-ready like every other model here: no `@Attribute(.unique)`, every
// stored attribute defaulted. The three profile-ish singletons follow the
// `ATPConfig` constant-id pattern (one row each); `SportProgressRecord` is keyed
// by sport, `FeedbackRecord` by a stable UUID so distinct feedback is never
// collapsed by `TrainingDataStore.deduplicate()`.

/// Athlete identity + season-agnostic facts. Singleton. The performance scalars
/// that used to share `coach_memory.json` (FTP/CSS/zones) are NOT here — they live
/// in the `PerformanceMetricRecord` time series.
@Model
final class ProfileRecord {
    static let singletonID = "coach_profile"
    var id: String = ProfileRecord.singletonID
    var name: String?
    var goals: [String] = []
    /// The "why" behind the goals — changes coaching trade-offs, not just tone.
    var motivation: String?
    var latitude: Double?
    var longitude: Double?
    /// Retained for the append-only CloudKit schema; no longer read — the
    /// onboarding prompt section now gates purely on missing profile data.
    var onboardingComplete: Bool = false

    init() {}
}

/// Weekly volume shape + the ATP sport-split inputs. Singleton.
@Model
final class WeeklyStructureRecord {
    static let singletonID = "coach_weekly_structure"
    var id: String = WeeklyStructureRecord.singletonID
    var maxHours: Int?
    var preferredRestDay: String?
    var longRunDay: String?
    var longRideDay: String?
    /// `SportFamily` raw value → weekly-TSS weight (the ATP `sport_ratio`).
    var sportRatio: [String: Double] = [:]
    /// `SportFamily` raw value → minimum weekly TSS floor.
    var sportFloors: [String: Double] = [:]

    init() {}
}

/// Scheduling constraints/preferences. Singleton.
@Model
final class PreferencesRecord {
    static let singletonID = "coach_preferences"
    var id: String = PreferencesRecord.singletonID
    // The structured fields below are retained for the append-only CloudKit
    // schema only: the read path folds any pre-fold values into
    // `trainingPreferences` as plain entries, and the next save clears them.
    var noSwimDays: [String] = []
    var noBikeDays: [String] = []
    var noRunDays: [String] = []
    var morningWorkouts: Bool?
    var indoorTrainerAvailable: Bool?
    /// Free-text training likes/dislikes ("Run: likes strides"). Honored by
    /// default when building workouts — guidance, not binding limitations.
    var trainingPreferences: [String] = []

    init() {}
}

/// Per-discipline ability/limitation/injury picture. One row per sport key.
/// `limitations` / `injuriesAffecting` are stored as Codable value arrays (they're
/// tightly coupled to the sport, so they don't need independent cross-device merge).
@Model
final class SportProgressRecord {
    /// Lowercased sport key ("swimming"/"cycling"/"running"/"strength") — natural key.
    var sport: String = ""
    var currentLevel: String?
    var abilities: [String] = []
    var limitations: [Limitation] = []
    var injuriesAffecting: [InjuryImpact] = []
    var currentFocus: String?
    var maxContinuous: String?
    var equipment: [String] = []
    var notes: String?

    init(sport: String) { self.sport = sport }
}

/// One dated piece of athlete feedback. Keyed by a stable UUID so two devices each
/// adding feedback both survive a merge (only a true row-duplicate collapses).
@Model
final class FeedbackRecord {
    var id: String = ""
    var date: Date = Date.distantPast
    var category: String = "general"
    var feedback: String = ""

    init(id: String = UUID().uuidString, date: Date, category: String, feedback: String) {
        self.id = id
        self.date = date
        self.category = category
        self.feedback = feedback
    }
}
