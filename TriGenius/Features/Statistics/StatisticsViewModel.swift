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

    enum StatsRange: String, CaseIterable, Identifiable {
        case oneMonth = "1M"
        case threeMonths = "3M"
        case sixMonths = "6M"
        case oneYear = "1Y"

        var id: String { rawValue }
        var weeks: Int {
            switch self {
            case .oneMonth: return 4
            case .threeMonths: return 13
            case .sixMonths: return 26
            case .oneYear: return 52
            }
        }
    }

    var range: StatsRange = .threeMonths { didSet { load() } }
    var shareMetric: SportShareModel.Metric = .tss { didSet { rebuildShare() } }
    var zoneSport: SportFamily = .run { didSet { rebuildZones() } }

    private(set) var pmc: PMCResult?
    private(set) var share = SportShareModel(metric: .tss, weeks: [])
    private(set) var zoneHR: [Double] = []
    private(set) var zonePower: [Double] = []
    private(set) var ramp: [RampWeek] = []
    private(set) var powerCurve: [PowerCurve.Point] = []

    private var records: [WorkoutRecord] = []

    /// This week's fitness gain so far — the hero number.
    var currentRampDelta: Double? { ramp.last?.delta }

    func load() {
        let now = Date()
        guard let windowStart = TrainingVolume.recentWeekStarts(weeks: range.weeks, today: now).first
        else { return }
        records = TrainingDataStore.shared.activities(from: windowStart, to: now)

        let result = PMCEngine.current()
        pmc = result
        ramp = RampRate.weeklySeries(points: result.points, weeks: range.weeks, today: now)

        rebuildShare()
        rebuildZones()
        powerCurve = PowerCurve.aggregate(records: records)
    }

    private func rebuildShare() {
        share = SportShareModel.make(records: records, weeks: range.weeks, metric: shareMetric)
    }

    private func rebuildZones() {
        let sportRecords = records.filter { SportFamily(sportKey: $0.sport) == zoneSport }
        zoneHR = ZoneDistribution.aggregate(records: sportRecords, source: .heartRate)
        zonePower = ZoneDistribution.aggregate(records: sportRecords, source: .power)
    }

}
