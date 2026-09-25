import Foundation

// MARK: - Statistics ViewModel
//
// Store-fed state for the Statistics screen: one activity fetch per range, then
// pure Analytics-layer aggregation into the shared chart models. Picker changes
// that don't widen the window (share metric, zone sport) recompute from the
// cached records without re-fetching.

@MainActor
@Observable
final class StatisticsViewModel {

    var range: TimeRange = .threeMonths { didSet { load() } }
    var shareMetric: SportShareModel.Metric = .tss { didSet { rebuildShare() } }
    var zoneSport: SportFamily = .run { didSet { rebuildZones() } }

    private(set) var pmc: PMCResult?
    /// Actual vs planned fitness over the range, plus the plan just ahead.
    private(set) var ctlTrend = CTLTrendModel(actual: [], planned: [])
    private(set) var week: WeekTargets?
    private(set) var share = SportShareModel(metric: .tss, weeks: [])
    private(set) var zones: [ZoneMetric: [Double]] = [:]
    /// Today's bounds, not each workout's own — the range can span a threshold
    /// change, so the card labels them as current (`ZoneDistributionStack`).
    private(set) var zoneBounds: [ZoneMetric: [Double]] = [:]
    private(set) var powerCurve: [PowerCurve.Point] = []

    private var records: [WorkoutRecord] = []
    private var weeks = 0
    private let weeklyStructure: WeeklyStructure

    init(weeklyStructure: WeeklyStructure) {
        self.weeklyStructure = weeklyStructure
    }

    func load() {
        let now = Date()
        let result = PMCEngine.current()
        pmc = result
        let plan = ATPEngine.current()
        ctlTrend = CTLTrendModel.around(points: result.points, planCurve: plan?.planCurve ?? [],
                                        from: range.start(now: now) ?? result.points.first?.date, today: now)
        week = WeeklyTargets.thisWeek(weeklyStructure: weeklyStructure, atpPlan: plan,
                                      creditFactor: AppSettings.storedCreditFactor(), today: now)
        weeks = range.weeks(first: result.points.first?.date)
        guard let windowStart = TrainingVolume.recentWeekStarts(weeks: weeks, today: now).first
        else { return }
        records = TrainingDataStore.shared.activities(from: windowStart, to: now)

        rebuildShare()
        rebuildZones()
        powerCurve = PowerCurve.aggregate(records: records)
    }

    private func rebuildShare() {
        share = SportShareModel.make(records: records, weeks: weeks, metric: shareMetric)
    }

    private func rebuildZones() {
        let snapshot = TrainingDataStore.shared.latestSnapshot()
        zones = ZoneMetric.allCases.reduce(into: [:]) {
            $0[$1] = ZoneDistribution.aggregate(records: records, metric: $1, family: zoneSport)
        }
        zoneBounds = ZoneMetric.allCases.reduce(into: [:]) {
            $0[$1] = $1.upperBounds(snapshot: snapshot, family: zoneSport)
        }
    }

}
