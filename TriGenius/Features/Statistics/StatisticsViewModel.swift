import Foundation

// MARK: - Statistics ViewModel
//
// Store-fed state behind every `StatCard` — the Statistics screen and the dashboard's
// Pinned section: one activity fetch per range, then pure Analytics-layer aggregation
// into the shared chart models. Picker changes that don't widen the window (share
// metric, zone sport) recompute from the cached records without re-fetching.

@MainActor
@Observable
final class StatisticsViewModel {

    var range: TimeRange { didSet { load() } }
    var shareMetric: SportShareModel.Metric = .tss { didSet { rebuildShare() } }
    var zoneSport: SportFamily = .run { didSet { rebuildZones() } }
    var weeklyStructure: WeeklyStructure
    /// The cards to load for; nil loads them all (the Statistics screen).
    var cards: [StatCard]?

    private(set) var pmc: PMCResult?
    /// Actual vs planned fitness over the range, plus the plan just ahead.
    private(set) var ctlTrend = CTLTrendModel(actual: [], planned: [])
    private(set) var plan: ATPPlan?
    private(set) var week: WeekTargets?
    private(set) var share = SportShareModel(metric: .tss, weeks: [])
    private(set) var zones: [ZoneMetric: [Double]] = [:]
    /// Today's bounds, not each workout's own — the range can span a threshold
    /// change, so the card labels them as current (`ZoneDistributionStack`).
    private(set) var zoneBounds: [ZoneMetric: [Double]] = [:]
    private(set) var powerCurve: [PowerCurve.Point] = []
    /// The range's GPS tracks; nil until `RouteCache` has delivered them.
    private(set) var routes: [RouteLine]?
    /// Each marker's whole history by key; a marker without data has no entry.
    private(set) var histories: [String: [MetricPoint]] = [:]
    private(set) var metricsLoaded = false

    private var records: [WorkoutRecord] = []
    private var weeks = 0
    private var routeLoad: Task<Void, Never>?

    init(weeklyStructure: WeeklyStructure, range: TimeRange = .threeMonths) {
        self.weeklyStructure = weeklyStructure
        self.range = range
    }

    func load() {
        let now = Date()
        let result = PMCEngine.current()
        pmc = result
        plan = ATPEngine.current()
        ctlTrend = CTLTrendModel.around(pmc: result, planCurve: plan?.planCurve ?? [],
                                        from: range.start(now: now) ?? result.points.first?.date, today: now)
        week = WeeklyTargets.thisWeek(weeklyStructure: weeklyStructure, atpPlan: plan,
                                      creditFactor: AppSettings.storedCreditFactor(), today: now)
        weeks = range.weeks(first: result.points.first?.date)
        if cards?.contains(.routes) ?? true {
            routeLoad?.cancel()
            routeLoad = Task {
                let lines = await RouteCache.lines(since: range.start(now: now))
                if !Task.isCancelled, lines != routes { routes = lines }
            }
        }
        guard cards?.contains(where: StatCard.workoutCards.contains) ?? true,
              let windowStart = TrainingVolume.recentWeekStarts(weeks: weeks, today: now).first
        else { return }
        records = TrainingDataStore.shared.activities(from: windowStart, to: now)

        rebuildShare()
        rebuildZones()
        powerCurve = PowerCurve.aggregate(records: records)
    }

    /// The marker histories, which no range change touches.
    func loadMetrics() async {
        let store = TrainingDataStore.shared
        // Stored series first: they are one fetch each and must not wait for an estimate.
        let estimated = Set(PerformanceHistory.estimatedKeys)
        let metrics = PerformanceMetric.all.filter { cards?.contains(.metric($0)) ?? true }
        // An estimated marker shows the value in force now until its series is resolved.
        for metric in metrics where histories[metric.key] == nil {
            histories[metric.key] = store.currentEstimate(metric.key).map { [$0] }
        }
        for metric in metrics.sorted(by: { !estimated.contains($0.key) && estimated.contains($1.key) }) {
            let points = await store.metricHistory(metric.key)
            histories[metric.key] = points.isEmpty ? nil : points
        }
        metricsLoaded = true
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
