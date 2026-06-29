import Foundation
import SwiftData

// MARK: - Annual Training Plan (ATP) models
//
// The ATP is the season-long, event-anchored volume plan. Only INPUTS persist: a
// singleton config, the events, and sparse per-week overrides. The weekly grid
// (periods, weekly TSS, the daily CTL curves) is DERIVED by the pure ATP engine at
// read time — never stored. CTL is a daily series, so it lives in none of these.

/// Volume methodology. `weeklyTSS` distributes a weekly-average TSS across the
/// season; `targetCTL` back-solves the weekly TSS to hit each event's target CTL.
enum ATPMethodology: String, Codable, Sendable, CaseIterable {
    case weeklyTSS = "weekly_tss"
    case targetCTL = "target_ctl"
}

/// Event priority. A/B events anchor periodization + taper; C events are ignored
/// by the engine (they don't reshape the plan).
enum ATPEventPriority: String, Codable, Sendable, CaseIterable {
    case a = "A"
    case b = "B"
    case c = "C"
}

/// Sport family an event belongs to. Picks which `ATPEventType` options apply;
/// derived from the chosen type, never stored on its own.
enum ATPEventDiscipline: String, Codable, Sendable, CaseIterable {
    case triathlon, cycling, running, other

    var label: String {
        switch self {
        case .triathlon: "Triathlon"
        case .cycling: "Cycling"
        case .running: "Running"
        case .other: "Other"
        }
    }
}

/// Specific event type within a discipline — TrainingPeaks' per-discipline lists
/// (ATP_TODO Appendix B). The duration bucket the suggested-volume helper keys on.
enum ATPEventType: String, Codable, Sendable, CaseIterable {
    // Triathlon
    case triSprint = "tri_sprint"
    case triOlympic = "tri_olympic"
    case triHalf = "tri_half"
    case triFull = "tri_full"
    // Cycling
    case roadRace = "road_race"
    case century = "century"
    case gravelFondo = "gravel_fondo"
    case mtbXCO = "mtb_xco"
    case mtbMarathon = "mtb_marathon"
    case mtbUltra = "mtb_ultra"
    // Running
    case run5k10k = "run_5k_10k"
    case halfMarathon = "half_marathon"
    case marathon = "marathon"
    case ultra = "ultra"
    // Other (by "A" race duration)
    case otherUpTo3h = "other_up_to_3h"
    case other3to8h = "other_3_to_8h"
    case other8hPlus = "other_8h_plus"

    var discipline: ATPEventDiscipline {
        switch self {
        case .triSprint, .triOlympic, .triHalf, .triFull: .triathlon
        case .roadRace, .century, .gravelFondo, .mtbXCO, .mtbMarathon, .mtbUltra: .cycling
        case .run5k10k, .halfMarathon, .marathon, .ultra: .running
        case .otherUpTo3h, .other3to8h, .other8hPlus: .other
        }
    }

    var label: String {
        switch self {
        case .triSprint: "Sprint"
        case .triOlympic: "Olympic"
        case .triHalf: "Half-Distance"
        case .triFull: "Full-Distance"
        case .roadRace: "Road Racing"
        case .century: "Century / Metric"
        case .gravelFondo: "Gravel / Fondo"
        case .mtbXCO: "MTB XCO"
        case .mtbMarathon: "MTB Marathon"
        case .mtbUltra: "MTB Ultra"
        case .run5k10k: "5k–10k"
        case .halfMarathon: "Half-Marathon"
        case .marathon: "Marathon"
        case .ultra: "Ultra"
        case .otherUpTo3h: "Up to 3h"
        case .other3to8h: "3–8h"
        case .other8hPlus: "8h+"
        }
    }

    /// The types belonging to a discipline, in declaration order.
    static func types(in discipline: ATPEventDiscipline) -> [ATPEventType] {
        allCases.filter { $0.discipline == discipline }
    }
}

/// Singleton ATP config — "the thing that computes target TSS". One athlete ⇒ one
/// plan, so there is at most one row (no name / active flag); the constant unique
/// `id` makes that structural. No `endDate`: the horizon rolls to the last event.
@Model
final class ATPConfig {
    static let singletonID = "atp_config"
    @Attribute(.unique) var id: String = ATPConfig.singletonID

    /// Anchor day the plan-CTL projection starts from (start of day, local).
    var startDate: Date
    /// Seed CTL at `startDate`. Nil ⇒ derive from the PMC at `startDate`; a stored
    /// value is only needed when the plan starts without enough history.
    var startingCTL: Double?
    var methodology: ATPMethodology
    /// Recovery cadence: an easier week every N (3 or 4).
    var recoveryCycle: Int
    /// Max sustainable weekly ΔCTL the target-CTL back-solver may schedule.
    var maxRampRate: Double
    /// The ONLY weekly-TSS-mode input; easiest/hardest week + annual are derived.
    var weeklyAverageTSS: Double

    init(startDate: Date, startingCTL: Double? = nil, methodology: ATPMethodology,
         recoveryCycle: Int = 4, maxRampRate: Double = 7, weeklyAverageTSS: Double = 0) {
        self.startDate = startDate
        self.startingCTL = startingCTL
        self.methodology = methodology
        self.recoveryCycle = recoveryCycle
        self.maxRampRate = maxRampRate
        self.weeklyAverageTSS = weeklyAverageTSS
    }
}

/// One target event. A/B anchor periodization + taper; C is ignored by the engine.
/// The duration bucket lives in `eventType` (drives the suggested-volume helper).
@Model
final class ATPEvent {
    @Attribute(.unique) var id: String
    var name: String
    /// Event day (start of day, local).
    var date: Date
    /// Discipline + duration bucket; its `discipline` drives the suggested-volume helper.
    var eventType: ATPEventType
    var priority: ATPEventPriority
    /// Target CTL on the event day (target-CTL methodology). Nil otherwise.
    var targetCTL: Double?
    /// Free-text description; coach context. Detailed goals (time/place/PR) deferred.
    var notes: String

    init(id: String = UUID().uuidString, name: String, date: Date, eventType: ATPEventType,
         priority: ATPEventPriority, targetCTL: Double? = nil, notes: String = "") {
        self.id = id
        self.name = name
        self.date = date
        self.eventType = eventType
        self.priority = priority
        self.targetCTL = targetCTL
        self.notes = notes
    }
}

/// A whole-week TSS pin the athlete set (sparse — one row per pinned week). The
/// engine treats it as a hard constraint and solves the free neighbours around it.
@Model
final class ATPWeekOverride {
    /// Monday (start of day, local) of the pinned week — the natural unique key.
    @Attribute(.unique) var weekStart: Date
    /// Pinned weekly TSS; 0 = rest / vacation.
    var pinnedTSS: Double
    var note: String

    init(weekStart: Date, pinnedTSS: Double, note: String = "") {
        self.weekStart = weekStart
        self.pinnedTSS = pinnedTSS
        self.note = note
    }
}

// MARK: - Value DTOs (cross the actor boundary into the pure engine)

/// Sendable mirror of `ATPConfig` fed to the pure ATP engine.
struct ATPParams: Sendable {
    let startDate: Date
    let startingCTL: Double?
    let methodology: ATPMethodology
    let recoveryCycle: Int
    let maxRampRate: Double
    let weeklyAverageTSS: Double
}

/// Sendable mirror of `ATPEvent`.
struct ATPEventInput: Sendable, Identifiable {
    let id: String
    let name: String
    let date: Date
    let eventType: ATPEventType
    let priority: ATPEventPriority
    let targetCTL: Double?
    let notes: String
}

/// Sendable mirror of `ATPWeekOverride`.
struct ATPWeekOverrideInput: Sendable {
    let weekStart: Date
    let pinnedTSS: Double
    let note: String
}
