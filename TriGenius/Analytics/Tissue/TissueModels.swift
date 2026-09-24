import Foundation

// MARK: - Tissue Load domain types
//
// Strength load never enters TSS/CTL — that axis is cardiovascular. Instead every
// session (swim, bike, run, strength) maps onto tissue groups, and each group
// carries a forecast of when it is clear for hard work again. That forecast is the
// primary value in every surface; the levels behind it are the evidence.
//
// These are the types the UI consumes. The model that derives them from sessions
// fills them in.

/// Canonical tissue groups. `label` is the only user-facing name anywhere in the app
/// (≤ 11 characters, no slashes). `allCases` order is the anatomical tie-break order
/// every sort ends on, so rows never shuffle between equal values.
///
/// The trunk has no front group: abs and obliques count as "Low back", the chest as
/// "Shoulders" (`GarminMuscles`).
nonisolated enum TissueGroup: String, CaseIterable, Codable, Hashable, Sendable {
    case calves, shins, hamstrings, quads, glutes, hipFlexors, adductors, lowBack, upperBack, shoulders,
         biceps, triceps, forearms

    var label: String {
        switch self {
        case .calves: return "Calves"
        case .shins: return "Shins"
        case .hamstrings: return "Hamstrings"
        case .quads: return "Quads"
        case .glutes: return "Glutes"
        case .hipFlexors: return "Hip flexors"
        case .adductors: return "Adductors"
        case .lowBack: return "Low back"
        case .upperBack: return "Upper back"
        case .shoulders: return "Shoulders"
        case .biceps: return "Biceps"
        case .triceps: return "Triceps"
        case .forearms: return "Forearms"
        }
    }

    /// Name for the governing-tissue caption when the tendon limits the forecast.
    /// Nil → the caption reads "tendon".
    var tendonLabel: String? {
        switch self {
        case .calves: return "Achilles"
        case .hamstrings: return "proximal hamstring"
        case .quads: return "patellar"
        case .shoulders: return "rotator cuff"
        default: return nil
        }
    }

    var anatomicalRank: Int { TissueGroup.allCases.firstIndex(of: self) ?? 0 }

    /// Drives the card's "Legs today / Upper body" language. The trunk counts as upper
    /// body: an athlete told to stay off the legs can still train it.
    var isLowerBody: Bool {
        switch self {
        case .calves, .shins, .hamstrings, .quads, .glutes, .hipFlexors, .adductors: return true
        case .lowBack, .upperBack, .shoulders, .biceps, .triceps, .forearms: return false
        }
    }
}

nonisolated enum TissueKind: String, Codable, Sendable { case muscle, tendon }

// MARK: - Load

/// Ordinal load level. Never rendered as a percentage — the model isn't that precise.
nonisolated enum LoadLevel: Int, Codable, Comparable, CaseIterable, Sendable {
    case fresh = 0, light = 1, moderate = 2, loaded = 3, heavy = 4

    static func < (a: LoadLevel, b: LoadLevel) -> Bool { a.rawValue < b.rawValue }

    /// "Clear for hard work" — the threshold the whole forecast is built on.
    var isClear: Bool { self <= .light }

    var word: String {
        switch self {
        case .fresh: return "Fresh"
        case .light: return "Light"
        case .moderate: return "Moderate"
        case .loaded: return "Loaded"
        case .heavy: return "Heavy"
        }
    }
}

/// Morning state of one group on one day. Past days come from logged sessions,
/// future days from the plan.
nonisolated struct TissueDayState: Codable, Hashable, Sendable {
    var date: Date
    var muscle: LoadLevel
    /// Nil when the group has no modelled tendon.
    var tendon: LoadLevel?

    /// Whichever tissue is worse. Ties go to the tendon: it clears more slowly and is
    /// the one that decides whether a hard session can happen.
    var governing: TissueKind {
        guard let tendon else { return .muscle }
        return tendon >= muscle && tendon >= .moderate ? .tendon : .muscle
    }

    var governingLevel: LoadLevel { governing == .tendon ? (tendon ?? muscle) : muscle }
}

nonisolated struct TissueForecast: Codable, Hashable, Sendable {
    var group: TissueGroup
    /// Consecutive days: the grid's past days, then today at `todayIndex`, then the
    /// days ahead. Everything that means "this morning" or "from now on" reads
    /// `today` / `ahead`, never an index of its own.
    var days: [TissueDayState]
    var todayIndex = 0
    /// The same days after that day's own sessions — what the lanes and cells draw, so
    /// a day with a workout shows its load on that day. `days` (the mornings) stays the
    /// basis for every decision: clear by, the lead line, the coach.
    var afterTraining: [TissueDayState] = []

    var today: TissueDayState? { days.indices.contains(todayIndex) ? days[todayIndex] : nil }
    var ahead: ArraySlice<TissueDayState> { days[min(todayIndex, days.count)...] }
}

// MARK: - Plan

nonisolated struct PlannedSession: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var date: Date
    var sport: SportFamily
    var title: String
    /// The window's heaviest planned session (`TissueLoadModel`) — the one the card's
    /// day header rings and the taper rows describe.
    var isKey: Bool
    /// Groups this session loads meaningfully, from the model's session mapping.
    var loads: Set<TissueGroup>
    var durationMinutes: Int
    /// What the session puts on each group — shown beside it in the group detail.
    var dose: [TissueGroup: TissueDose] = [:]
    /// The stored plan, so the detail can open it.
    var recordId: String?
}

/// A session already done that put load on a group — the "caused it" side of the
/// detail view. Separate from `PlannedSession` because only the plan can conflict.
nonisolated struct TissueDriver: Hashable, Sendable {
    var date: Date
    var sport: SportFamily
    var title: String
    var loads: Set<TissueGroup>
    var dose: [TissueGroup: TissueDose] = [:]
    /// The stored activity, so the detail can open it.
    var recordId: String?
}

nonisolated struct TissueConflict: Hashable, Sendable {
    var group: TissueGroup
    var tissue: TissueKind
    var session: PlannedSession
    var morningLevel: LoadLevel
}

// MARK: - Chronic (6 weeks)

/// Weekly load against what the plan phase asks of the group: −2…+2, 0 = inside the
/// target band. A different question from fatigue — this one is about neglect.
nonisolated struct ChronicWeek: Codable, Hashable, Sendable {
    var weekStart: Date
    var deviation: Int
}

nonisolated enum ChronicStatus: Equatable, Sendable {
    case under(weeks: Int), onTarget, over(weeks: Int)

    var word: String {
        switch self {
        case .under: return "Under"
        case .onTarget: return "On target"
        case .over: return "Over"
        }
    }

    /// Weeks spent off the target band — 0 when the group is inside it.
    var weeksOffTarget: Int {
        switch self {
        case .under(let weeks), .over(let weeks): return weeks
        case .onTarget: return 0
        }
    }
}
