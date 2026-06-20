import Foundation

// MARK: - Dashboard ViewModel
//
// Reads exclusively from the local `TrainingDataStore` (the source-agnostic
// single source of truth) plus the analytics layer — NOT live from HealthKit.
// HealthKit recovery metrics (steps/HRV/sleep) are an optional extra, only
// fetched when Apple Health is the active source.

@MainActor
@Observable
final class DashboardViewModel {
    var pmc: PMCResult?
    var weeklyBuckets: [TrainingVolume.WeekBucket] = []
    var recentWorkouts: [ActivityRecord] = []
    var healthMetrics: HealthMetricsSummary?
    var isLoading = false
    var errorMessage: String?

    private var hasLoaded = false

    /// The current (most recent) week bucket, for the "this week" summary.
    var currentWeek: TrainingVolume.WeekBucket? { weeklyBuckets.last }

    func loadInitialIfNeeded(dataSource: DataSource) async {
        guard !hasLoaded else { return }
        await load(dataSource: dataSource)
    }

    /// Re-sync from the active source, then recompute everything.
    func refresh(dataSource: DataSource) async {
        await DataSyncCoordinator.shared.sync(source: dataSource)
        await load(dataSource: dataSource)
    }

    func load(dataSource: DataSource) async {
        isLoading = true
        errorMessage = nil

        let store = TrainingDataStore.shared
        let records = store.activities() // newest first
        pmc = PMCEngine.current()
        recentWorkouts = Array(records.prefix(12))
        weeklyBuckets = TrainingVolume.weeklyBuckets(records: records)

        // Recovery metrics are HealthKit-only; skip for Garmin to avoid prompting.
        if dataSource == .appleHealth {
            healthMetrics = try? await HealthKitService.shared.fetchHealthMetrics(days: 7)
        } else {
            healthMetrics = nil
        }

        hasLoaded = true
        isLoading = false
    }
}
