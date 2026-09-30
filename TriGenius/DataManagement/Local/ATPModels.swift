import Foundation
import SwiftData

// MARK: - Annual Training Plan (ATP) models
//
// The ATP is the season-long, event-anchored volume plan. Only INPUTS persist: a
// singleton config, the events, and sparse per-week overrides. The weekly grid
// (periods, weekly TSS, the daily CTL curves) is DERIVED by the pure ATP engine at
// read time — never stored. CTL is a daily series, so it lives in none of these.
//
// CloudKit-readiness (NSPersistentCloudKitContainer): no `@Attribute(.unique)`
// (CloudKit can't enforce it — `TrainingDataStore.deduplicate()` is the merge-time
// safety net instead) and every stored attribute has a default. The enum defaults
// only satisfy the schema; every real row is fully populated through `init`.

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
nonisolated enum ATPEventDiscipline: String, Codable, Sendable, CaseIterable {
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
nonisolated enum ATPEventType: String, Codable, Sendable, CaseIterable {
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

    /// The legs a race of this type starts with. Distances only where the type fixes
    /// them; a range type (5k–10k, road race, ultra) leaves 0 for the athlete to set.
    var defaultLegs: [RaceLeg] {
        let meters: [Double]
        switch self {
        case .triSprint: meters = [750, 20_000, 5_000]
        case .triOlympic: meters = [1_500, 40_000, 10_000]
        case .triHalf: meters = [1_900, 90_000, 21_097.5]
        case .triFull: meters = [3_800, 180_000, 42_195]
        case .halfMarathon: meters = [21_097.5]
        case .marathon: meters = [42_195]
        case .century: meters = [160_934]
        default: meters = [0]
        }
        let sports: [SportFamily] = switch discipline {
        case .triathlon: SportFamily.triathlon
        case .cycling: [.bike]
        case .running: [.run]
        case .other: [.other]
        }
        return zip(sports, meters).map { RaceLeg(sport: $0, distanceMeters: $1) }
    }
}

/// How hard the athlete means to race: all out, or deliberately held back (a
/// training race, "just jogging along"). Scales the race IF (`RaceLoad`).
nonisolated enum RaceEffort: String, Codable, Sendable, CaseIterable {
    case race, controlled, easy

    var label: String {
        switch self {
        case .race: "All out"
        case .controlled: "Controlled"
        case .easy: "Easy"
        }
    }
}

/// One leg of a race — the whole race for a single-sport event. Everything past the
/// sport is the athlete's optional intent; `RaceLoad` fills what's missing.
nonisolated struct RaceLeg: Codable, Sendable, Hashable {
    var sport: SportFamily
    /// 0 = not set.
    var distanceMeters: Double = 0
    var goalMinutes: Double?
    var intensityFactor: Double?

    enum CodingKeys: String, CodingKey {
        case sport, distanceMeters = "distance_m", goalMinutes = "goal_minutes", intensityFactor = "intensity_factor"
    }

    /// "H:MM:SS" or "H:MM" → minutes.
    static func minutes(fromClock s: String) -> Double? {
        let parts = s.split(separator: ":").compactMap { Double($0) }
        guard parts.count == s.split(separator: ":").count, (2...3).contains(parts.count) else { return nil }
        return parts[0] * 60 + parts[1] + (parts.count == 3 ? parts[2] / 60 : 0)
    }

    /// Minutes → "H:MM:SS".
    static func clock(minutes: Double) -> String {
        let s = Int((minutes * 60).rounded())
        return String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
    }
}

/// Singleton ATP config — "the thing that computes target TSS". One athlete ⇒ one
/// plan, so there is at most one row (no name / active flag); the constant unique
/// `id` makes that structural. No `endDate`: the horizon rolls to the last event.
@Model
final class ATPConfig {
    static let singletonID = "atp_config"
    var id: String = ATPConfig.singletonID

    /// Anchor day the plan-CTL projection starts from (start of day, local).
    var startDate: Date = Date.distantPast
    /// Seed CTL at `startDate`. Nil ⇒ derive from the PMC at `startDate`; a stored
    /// value is only needed when the plan starts without enough history.
    var startingCTL: Double?
    var methodology: ATPMethodology = ATPMethodology.weeklyTSS
    /// Recovery cadence: an easier week every N (3 or 4).
    var recoveryCycle: Int = 4
    /// Max sustainable weekly ΔCTL the target-CTL back-solver may schedule.
    var maxRampRate: Double = 7
    /// The ONLY weekly-TSS-mode input; easiest/hardest week + annual are derived.
    var weeklyAverageTSS: Double = 0

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
    var id: String = ""
    var name: String = ""
    /// Event day (start of day, local).
    var date: Date = Date.distantPast
    /// Discipline + duration bucket; its `discipline` drives the suggested-volume helper.
    var eventType: ATPEventType = ATPEventType.triOlympic
    var priority: ATPEventPriority = ATPEventPriority.c
    /// Target CTL on the event day (target-CTL methodology). Nil otherwise.
    var targetCTL: Double?
    /// Free-text description; coach context.
    var notes: String = ""
    /// Start time, minutes after midnight (local). Nil → no time set.
    var startMinute: Int?
    /// Optional because SwiftData can't fill a new enum attribute on rows stored
    /// before it existed — a non-optional one crashes the first read. Nil = all out.
    var effort: RaceEffort?
    /// `[RaceLeg]`, JSON-encoded; "" for an event saved before legs existed.
    var legsJSON: String = ""

    init(_ e: ATPEventInput) {
        id = e.id
        apply(e)
    }

    func apply(_ e: ATPEventInput) {
        name = e.name
        date = e.date
        eventType = e.eventType
        priority = e.priority
        targetCTL = e.targetCTL
        notes = e.notes
        startMinute = e.startMinute
        effort = e.effort
        legsJSON = (try? JSONEncoder().encode(e.legs)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    var input: ATPEventInput {
        let legs = legsJSON.data(using: .utf8).flatMap { try? JSONDecoder().decode([RaceLeg].self, from: $0) }
        return ATPEventInput(id: id, name: name, date: date, eventType: eventType, priority: priority,
                             targetCTL: targetCTL, notes: notes, startMinute: startMinute, effort: effort ?? .race,
                             legs: legs ?? eventType.defaultLegs)
    }
}

/// A whole-week TSS pin the athlete set (sparse — one row per pinned week). The
/// engine treats it as a hard constraint and solves the free neighbours around it.
@Model
final class ATPWeekOverride {
    /// Monday (start of day, local) of the pinned week — the natural key.
    var weekStart: Date = Date.distantPast
    /// Pinned weekly TSS; 0 = rest / vacation.
    var pinnedTSS: Double = 0
    var note: String = ""

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

/// Sendable mirror of `ATPEvent`, and the event editor's draft.
struct ATPEventInput: Sendable, Identifiable, Hashable {
    let id: String
    var name: String
    var date: Date
    var eventType: ATPEventType
    var priority: ATPEventPriority
    var targetCTL: Double?
    var notes: String
    var startMinute: Int? = nil
    var effort: RaceEffort = .race
    var legs: [RaceLeg] = []
}

/// Sendable mirror of `ATPWeekOverride`.
struct ATPWeekOverrideInput: Sendable {
    let weekStart: Date
    let pinnedTSS: Double
    let note: String
}
