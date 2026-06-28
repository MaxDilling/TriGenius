import Foundation

// MARK: - ATP periods + tuning constants
//
// The SINGLE source of every ATP shape constant — no magic numbers in the engine.
// These are *initial* values, meant to be fit against a corpus of TrainingPeaks
// example plans in `ref/atp_lab/` and then hand-ported back here (see ATP_TODO.md).
// Tuning the season shape = editing this file, nothing else.

/// Periodization blocks, ordered base → race. `transition` is the post-event /
/// "Not-Set" recovery tail.
enum ATPPeriod: String, Codable, Sendable, CaseIterable {
    case base1, base2, base3, build1, build2, peak, race, transition

    var label: String {
        switch self {
        case .base1: "Base 1"; case .base2: "Base 2"; case .base3: "Base 3"
        case .build1: "Build 1"; case .build2: "Build 2"; case .peak: "Peak"
        case .race: "Race"; case .transition: "Transition"
        }
    }
}

enum ATPConstants {

    // MARK: Periodization layout

    /// Nominal length (weeks) of each block, consumed backward from an A event.
    /// Surplus season weeks extend Base 1 (the foundation stretches); a short run-in
    /// drops blocks from the base end first, keeping the race-proximal taper intact.
    static let nominalWeeks: [ATPPeriod: Int] = [
        .base1: 4, .base2: 4, .base3: 4, .build1: 3, .build2: 3, .peak: 2, .race: 1, .transition: 1,
    ]

    /// Ladder consumed backward from each A event (race-proximal first).
    static let ladder: [ATPPeriod] = [.race, .peak, .build2, .build1, .base3, .base2, .base1]

    /// Recovery weeks after an A event before the next block begins (also the tail
    /// length past the last event).
    static let transitionWeeks = 1

    /// Weeks of detraining tail the CTL curves run past the last event ("Not-Set"
    /// decay) — drawn beyond the last plan bar so the post-event drop is visible.
    static let chartTailWeeks = 5

    /// Taper length (weeks ending at the event) by priority. C events never taper.
    static func taperWeeks(_ p: ATPEventPriority) -> Int {
        switch p { case .a: 2; case .b: 1; case .c: 0 }
    }

    // MARK: Weekly-TSS shape

    /// Per-period multiplier on the weekly-average TSS (the relative load shape).
    static let periodLoad: [ATPPeriod: Double] = [
        .base1: 0.85, .base2: 0.95, .base3: 1.05, .build1: 1.15, .build2: 1.25,
        .peak: 0.80, .race: 0.50, .transition: 0.50,
    ]
    /// Recovery week load relative to its period (an easier week every N).
    static let recoveryLoadFactor = 0.60
    /// Mid-block (B-event) taper week load — peak/race already carry their own dip.
    static let taperLoadFactor = 0.70

    /// Hard bounds on a week's TSS, as fractions of the weekly average.
    static let easiestFraction = 0.60
    static let hardestFraction = 1.35

    // MARK: Starting-CTL estimate (Appendix A)

    /// Estimated CTL per weekly training hour, by athlete type (TP "Estimate
    /// Starting Fitness"). Seeds `startingCTL` when there isn't enough history.
    static let startingCTLPerHour: [String: Double] = [
        "cyclist": 7, "triathlete": 8, "runner": 9,
    ]
}
