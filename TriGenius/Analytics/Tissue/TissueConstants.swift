import Foundation

// MARK: - Tissue model constants
//
// Every number the tissue model computes with, in one place. All provisional —
// set from general sports-science knowledge, not fitted — until Phase 5
// calibrates them against real weeks (`TODO_KRAFTTRAINING.md`).

nonisolated enum TissueConstants {

    // MARK: Dose

    /// Dose per TL point, per group: running loads the lower leg eccentrically (the
    /// heaviest tendon load there is), cycling the quads and glutes concentrically,
    /// swimming the shoulders, upper back and the arms that pull.
    static let enduranceWeights: [SportFamily: [TissueGroup: TissueDose]] = [
        .run: [.calves: .init(muscle: 1.0, tendon: 1.0), .quads: .init(muscle: 0.8, tendon: 0.6),
               .hamstrings: .init(muscle: 0.7, tendon: 0.5), .glutes: .init(muscle: 0.6),
               .shins: .init(muscle: 0.5), .hipFlexors: .init(muscle: 0.5),
               .adductors: .init(muscle: 0.4), .lowBack: .init(muscle: 0.2)],
        .bike: [.quads: .init(muscle: 1.0, tendon: 0.3), .glutes: .init(muscle: 0.8),
                .hamstrings: .init(muscle: 0.4), .hipFlexors: .init(muscle: 0.4),
                .calves: .init(muscle: 0.3), .lowBack: .init(muscle: 0.3), .shins: .init(muscle: 0.2)],
        .swim: [.shoulders: .init(muscle: 1.0, tendon: 0.6), .upperBack: .init(muscle: 1.0),
                .triceps: .init(muscle: 0.7), .forearms: .init(muscle: 0.5),
                .biceps: .init(muscle: 0.3), .lowBack: .init(muscle: 0.3)],
    ]

    /// One hard set on a primary group, in TL points — the bridge between the two
    /// load axes.
    static let tlPerHardSet = 8.0
    /// A secondary group's share of a hard set.
    static let secondaryShare = 0.5

    // MARK: Decay

    static let muscleTimeConstantDays = 1.0
    static let tendonTimeConstantDays = 3.0

    // MARK: Levels

    static let baselineDays = 28
    /// A baseline never drops below this, so a group trained once in a while doesn't
    /// read a trickle of load as Heavy.
    static let baselineFloor = 5.0
    /// Upper bounds of state ÷ baseline for Fresh, Light, Moderate and Loaded; at or
    /// above the last is Heavy.
    static let levelBounds = [0.5, 1.0, 1.5, 2.0]

    // MARK: Conflicts

    static let peakDays = 30
    static let spikeMargin = 1.1
    static let minimumHistoryDays = 28
    /// A session loads a group when the group takes at least this share of its
    /// largest group dose.
    static let loadsShare = 0.25

    // MARK: Chronic

    static let chronicWeeks = 6
    /// Week ÷ 6-week average: below `farUnder` is −2, below `under` −1, up to `over`
    /// on target, up to `farOver` +1, above +2.
    static let chronicFarUnder = 0.5
    static let chronicUnder = 0.8
    static let chronicOver = 1.25
    static let chronicFarOver = 1.6

    // MARK: Windows

    /// Days of decay warm-up read before the chronic weeks.
    static let warmUpDays = 14
    /// Days the model reads behind today: the chronic weeks plus the decay's warm-up.
    static let historyDays = 7 * (chronicWeeks + 1) + warmUpDays
    /// How far back a completed session still counts as a driver of today's state.
    static let driverDays = 3
    /// Below this many scored sessions the forecast is too thin to lead with advice, so
    /// the card says so instead.
    static let minimumSessionsForAdvice = 20
}
