import Foundation

// MARK: - Race load (expected duration + TSS of a planned race)
//
// Per leg: duration is the goal time, else the distance at the leg's race speed. IF
// is the athlete's own value, else the goal pace against threshold (swim/run), else
// the effort-scaled race IF at the race's TOTAL duration — a leg of a long race is
// paced for the whole race, not for its own length. Race IF and total duration
// depend on each other; the curve is flat enough that a few fixed-point rounds
// settle it. Cycling has no threshold speed, so a bike leg without a goal time runs
// at the flat typical speed (`PlannedTSS.speedMPS`).

struct RaceLegLoad {
    let sport: SportFamily
    let distanceMeters: Double
    let minutes: Double
    let intensityFactor: Double
    let tss: Double
    /// IF from the race curve, not from the athlete's goal time or own value.
    let isEstimated: Bool
}

enum RaceLoad {

    static func legs(_ legs: [RaceLeg], effort: RaceEffort, thresholds: PerformanceSnapshot) -> [RaceLegLoad] {
        var raceIF = intensity(hours: 1, effort: effort)
        for _ in 0 ..< 4 {
            let minutes = legs.reduce(0) { $0 + load($1, raceIF: raceIF, thresholds: thresholds).minutes }
            raceIF = intensity(hours: minutes / 60, effort: effort)
        }
        return legs.map { load($0, raceIF: raceIF, thresholds: thresholds) }
    }

    /// The race IF for a race of `hours` total at `effort` (`TSSConstants.raceAllOutIF`).
    static func intensity(hours: Double, effort: RaceEffort) -> Double {
        let share = switch effort {
        case .race: 1.0
        case .controlled: TSSConstants.raceControlledShare
        case .easy: TSSConstants.raceEasyShare
        }
        let anchors = TSSConstants.raceAllOutIF
        guard hours > anchors[0].hours else { return share * anchors[0].intensity }
        guard let i = anchors.firstIndex(where: { $0.hours >= hours }) else { return share * anchors[anchors.count - 1].intensity }
        let (a, b) = (anchors[i - 1], anchors[i])
        let t = log(hours / a.hours) / log(b.hours / a.hours)
        return share * (a.intensity + t * (b.intensity - a.intensity))
    }

    private static func load(_ leg: RaceLeg, raceIF: Double, thresholds: PerformanceSnapshot) -> RaceLegLoad {
        let goalSeconds = leg.goalMinutes.flatMap { $0 > 0 ? $0 * 60 : nil }
        let goalIF = goalSeconds.flatMap { seconds -> Double? in
            guard leg.distanceMeters > 0,
                  let threshold = PlannedTSS.thresholdSpeedMPS(leg.sport, thresholds: thresholds) else { return nil }
            return PlannedTSS.clamp(leg.distanceMeters / seconds / threshold)
        }
        let intensity = leg.intensityFactor ?? goalIF ?? raceIF
        let seconds = goalSeconds
            ?? leg.distanceMeters / PlannedTSS.speedMPS(leg.sport, intensity: intensity, thresholds: thresholds)
        return RaceLegLoad(sport: leg.sport, distanceMeters: leg.distanceMeters, minutes: seconds / 60,
                           intensityFactor: intensity, tss: PlannedTSS.load(intensity: intensity, seconds: seconds),
                           isEstimated: leg.intensityFactor == nil && goalIF == nil)
    }
}
