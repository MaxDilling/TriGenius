import Foundation
import HealthKit

// MARK: - HealthKit Service
//
// Provides training & health data to the AI coach via HealthKit.
// Replaces the Garmin integration from the Python app.

final class HealthKitService {
    static let shared = HealthKitService()
    private let store = HKHealthStore()
    private var authorized = false

    private init() {}

    // MARK: - Authorization

    func requestAuthorization() async throws {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw HKServiceError.notAvailable
        }

        let readTypes: Set<HKObjectType> = [
            HKObjectType.workoutType(),
            HKQuantityType(.heartRate),
            HKQuantityType(.restingHeartRate),
            HKQuantityType(.heartRateVariabilitySDNN),
            HKQuantityType(.stepCount),
            HKQuantityType(.activeEnergyBurned),
            HKQuantityType(.distanceWalkingRunning),
            HKQuantityType(.distanceCycling),
            HKQuantityType(.distanceSwimming),
            HKQuantityType(.oxygenSaturation),
            HKQuantityType(.respiratoryRate),
            HKQuantityType(.cyclingFunctionalThresholdPower),
            HKQuantityType(.vo2Max),
            HKQuantityType(.bodyMass),
            HKCategoryType(.sleepAnalysis)
        ]

        try await store.requestAuthorization(toShare: [], read: readTypes)
        authorized = true
    }

    // MARK: - Recent Workouts

    /// `since` bounds the query to workouts on/after that date — used by the
    /// incremental sync so only new activities are fetched.
    func fetchRecentWorkouts(count: Int = 10, since: Date? = nil) async throws -> [WorkoutSummary] {
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
        let predicate = since.map { HKQuery.predicateForSamples(withStart: $0, end: nil) }
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: .workoutType(),
                predicate: predicate,
                limit: count,
                sortDescriptors: [sort]
            ) { _, samples, error in
                if let error { continuation.resume(throwing: error); return }
                let workouts = (samples as? [HKWorkout] ?? [])
                    .filter { !HealthKitService.isGarmin($0) }
                    .map(WorkoutSummary.init)
                continuation.resume(returning: workouts)
            }
            store.execute(query)
        }
    }

    // MARK: - Garmin source filtering

    /// Garmin Connect mirrors every workout it records into Apple Health, so when
    /// Apple Health is the active source those sessions show up as duplicates of
    /// the ones the Garmin integration already provides. Drop anything authored by
    /// the Garmin Connect app on import. Matches by source name ("Connect") and by
    /// bundle identifier ("com.garmin.connect.mobile") to be robust to either.
    private static func isGarmin(_ w: HKWorkout) -> Bool {
        let source = w.sourceRevision.source
        return source.bundleIdentifier.lowercased().contains("garmin")
            || source.name.caseInsensitiveCompare("Connect") == .orderedSame
    }

    // MARK: - Daily Health Metrics

    // MARK: - Heart Rate for Workout

    func fetchHeartRateSamples(during workout: HKWorkout) async throws -> [HeartRateSample] {
        guard let hrType = HKQuantityType.quantityType(forIdentifier: .heartRate) else {
            return []
        }
        let predicate = HKQuery.predicateForSamples(
            withStart: workout.startDate, end: workout.endDate
        )
        let unit = HKUnit.count().unitDivided(by: HKUnit.minute())
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: hrType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [sort]
            ) { _, samples, error in
                if let error { continuation.resume(throwing: error); return }
                let hrSamples = (samples as? [HKQuantitySample] ?? []).map {
                    HeartRateSample(date: $0.startDate, bpm: $0.quantity.doubleValue(for: unit))
                }
                continuation.resume(returning: hrSamples)
            }
            store.execute(query)
        }
    }

    // MARK: - Heart Rate CSV Export

    /// Refetches a workout by its UUID string (as stored in `WorkoutSummary.id`).
    func fetchWorkout(id: String) async throws -> HKWorkout? {
        guard let uuid = UUID(uuidString: id) else { return nil }
        let predicate = HKQuery.predicateForObject(with: uuid)
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: .workoutType(),
                predicate: predicate,
                limit: 1,
                sortDescriptors: nil
            ) { _, samples, error in
                if let error { continuation.resume(throwing: error); return }
                continuation.resume(returning: samples?.first as? HKWorkout)
            }
            store.execute(query)
        }
    }

    /// Builds a CSV string of heart rate samples for the given workout in the
    /// format: `Time,BPM,Source`.
    ///
    /// Uses `HKQuantitySeriesSampleQuery` to enumerate the high-resolution
    /// beat-to-beat data points stored *inside* each HR sample. A plain
    /// `HKSampleQuery` would only return the aggregated samples (≈ one point
    /// every 2.5 min), whereas the series query exposes the same 1-second
    /// resolution that the Apple Health app shows.
    func heartRateCSV(forWorkoutID id: String) async throws -> String {
        let header = "Time,BPM,Source\n"
        guard
            let workout = try await fetchWorkout(id: id),
            let hrType = HKQuantityType.quantityType(forIdentifier: .heartRate)
        else {
            return header
        }

        let predicate = HKQuery.predicateForSamples(
            withStart: workout.startDate, end: workout.endDate
        )
        let unit = HKUnit.count().unitDivided(by: HKUnit.minute())

        let points: [(date: Date, bpm: Double, source: String)] = try await withCheckedThrowingContinuation { continuation in
            var collected: [(date: Date, bpm: Double, source: String)] = []
            var didResume = false

            let query = HKQuantitySeriesSampleQuery(
                quantityType: hrType,
                predicate: predicate
            ) { _, quantity, dateInterval, sample, done, error in
                if let error {
                    if !didResume { didResume = true; continuation.resume(throwing: error) }
                    return
                }
                if let quantity, let dateInterval {
                    let source = sample?.sourceRevision.source.name ?? "Unknown"
                    collected.append((dateInterval.start, quantity.doubleValue(for: unit), source))
                }
                if done, !didResume {
                    didResume = true
                    continuation.resume(returning: collected)
                }
            }
            store.execute(query)
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        var rows = ["Time,BPM,Source"]
        for point in points.sorted(by: { $0.date < $1.date }) {
            let time = formatter.string(from: point.date)
            rows.append("\(time),\(point.bpm),\"\(point.source)\"")
        }
        return rows.joined(separator: "\n") + "\n"
    }

    // MARK: - Performance metrics

    /// Fetch the latest performance values Apple Health exposes (FTP, VO2max).
    /// CSS is not available in HealthKit, so it is simply omitted.
    func fetchPerformanceMetrics() async throws -> [IngestedMetric] {
        var out: [IngestedMetric] = []
        let now = Date()
        if let ftp = try await fetchLatestQuantity(
            HKQuantityType(.cyclingFunctionalThresholdPower), unit: .watt()
        ), ftp > 0 {
            out.append(IngestedMetric(metricKey: "cycling_ftp", value: ftp, unit: "watts", source: "healthkit", date: now))
        }
        let vo2Unit = HKUnit.literUnit(with: .milli).unitDivided(by: .gramUnit(with: .kilo).unitMultiplied(by: .minute()))
        if let vo2 = try await fetchLatestQuantity(HKQuantityType(.vo2Max), unit: vo2Unit), vo2 > 0 {
            out.append(IngestedMetric(metricKey: "vo2max_running", value: vo2, unit: "ml_kg_min", source: "healthkit", date: now))
        }
        if let weight = try await fetchLatestQuantity(HKQuantityType(.bodyMass), unit: .gramUnit(with: .kilo)), weight > 0 {
            out.append(IngestedMetric(metricKey: "weight_kg", value: weight, unit: "kg", source: "healthkit", date: now))
        }
        return out
    }

    // MARK: - Daily wellness (sleep / resting HR / HRV)

    /// Daily wellness time series Apple Health exposes — resting HR, overnight HRV
    /// (SDNN, ms) and sleep duration + stage breakdown. Mirrors the Garmin wellness
    /// ingest so `MetricKeys.wellness` is populated source-agnostically. Apple Health
    /// has no native sleep *score*, so `sleep_score` is omitted (only durations).
    func fetchWellnessMetrics(since: Date?) async throws -> [IngestedMetric] {
        let start = since ?? Calendar.current.date(byAdding: .day, value: -30, to: Calendar.current.startOfDay(for: Date()))!
        async let rhr = dailyAverage(HKQuantityType(.restingHeartRate),
                                     unit: HKUnit.count().unitDivided(by: .minute()),
                                     key: "resting_hr", unitToken: "bpm", since: start)
        async let hrv = dailyAverage(HKQuantityType(.heartRateVariabilitySDNN),
                                     unit: HKUnit.secondUnit(with: .milli),
                                     key: "hrv_overnight", unitToken: "ms", since: start)
        async let sleep = sleepMetrics(since: start)
        return try await rhr + hrv + sleep
    }

    /// Average of a quantity per calendar day (bucketed by each sample's end date),
    /// emitted as one `IngestedMetric` per day under `key`.
    private func dailyAverage(_ type: HKQuantityType, unit: HKUnit, key: String,
                             unitToken: String, since: Date) async throws -> [IngestedMetric] {
        let predicate = HKQuery.predicateForSamples(withStart: since, end: nil)
        let samples: [HKQuantitySample] = try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(sampleType: type, predicate: predicate,
                                      limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, error in
                if let error { continuation.resume(throwing: error); return }
                continuation.resume(returning: (samples as? [HKQuantitySample]) ?? [])
            }
            store.execute(query)
        }
        let cal = Calendar.current
        var sums: [Date: (total: Double, n: Int)] = [:]
        for s in samples {
            let day = cal.startOfDay(for: s.endDate)
            let v = s.quantity.doubleValue(for: unit)
            let cur = sums[day] ?? (0, 0)
            sums[day] = (cur.total + v, cur.n + 1)
        }
        return sums.map { day, agg in
            IngestedMetric(metricKey: key, value: agg.total / Double(agg.n), unit: unitToken, source: "healthkit", date: day)
        }
    }

    /// Per-night sleep duration + stage breakdown (hours), bucketed by wake day.
    private func sleepMetrics(since: Date) async throws -> [IngestedMetric] {
        let predicate = HKQuery.predicateForSamples(withStart: since, end: nil)
        let samples: [HKCategorySample] = try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(sampleType: HKCategoryType(.sleepAnalysis), predicate: predicate,
                                      limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, error in
                if let error { continuation.resume(throwing: error); return }
                continuation.resume(returning: (samples as? [HKCategorySample]) ?? [])
            }
            store.execute(query)
        }
        let cal = Calendar.current
        // day → (deep, rem, light, awake) seconds
        var nights: [Date: (deep: Double, rem: Double, light: Double, awake: Double)] = [:]
        for s in samples {
            let day = cal.startOfDay(for: s.endDate)  // attribute the night to the wake day
            let dur = s.endDate.timeIntervalSince(s.startDate)
            var n = nights[day] ?? (0, 0, 0, 0)
            switch s.value {
            case HKCategoryValueSleepAnalysis.asleepDeep.rawValue: n.deep += dur
            case HKCategoryValueSleepAnalysis.asleepREM.rawValue: n.rem += dur
            case HKCategoryValueSleepAnalysis.asleepCore.rawValue,
                 HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue: n.light += dur
            case HKCategoryValueSleepAnalysis.awake.rawValue: n.awake += dur
            default: break  // inBed overlaps the stages — ignore to avoid double-counting
            }
            nights[day] = n
        }
        var out: [IngestedMetric] = []
        for (day, n) in nights {
            let asleep = n.deep + n.rem + n.light
            guard asleep > 0 else { continue }
            func h(_ s: Double) -> Double { s / 3600 }
            out.append(IngestedMetric(metricKey: "sleep_duration_h", value: h(asleep), unit: "h", source: "healthkit", date: day))
            out.append(IngestedMetric(metricKey: "sleep_deep_h", value: h(n.deep), unit: "h", source: "healthkit", date: day))
            out.append(IngestedMetric(metricKey: "sleep_rem_h", value: h(n.rem), unit: "h", source: "healthkit", date: day))
            out.append(IngestedMetric(metricKey: "sleep_light_h", value: h(n.light), unit: "h", source: "healthkit", date: day))
            out.append(IngestedMetric(metricKey: "sleep_awake_h", value: h(n.awake), unit: "h", source: "healthkit", date: day))
        }
        return out
    }

    /// Most recent sample for `type`, in `unit`, or nil if none.
    private func fetchLatestQuantity(_ type: HKQuantityType, unit: HKUnit) async throws -> Double? {
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: type, predicate: nil, limit: 1, sortDescriptors: [sort]
            ) { _, samples, error in
                if let error { continuation.resume(throwing: error); return }
                let value = (samples?.first as? HKQuantitySample)?.quantity.doubleValue(for: unit)
                continuation.resume(returning: value)
            }
            store.execute(query)
        }
    }

}

// MARK: - Data Models

nonisolated struct WorkoutSummary: Codable {
    let id: String
    let sport: String
    let name: String
    let date: String
    let durationMin: Double
    let distanceKm: Double?
    let avgHRbpm: Double?
    let totalEnergyKcal: Double?

    init(_ workout: HKWorkout) {
        id = workout.uuid.uuidString
        sport = WorkoutSummary.sportName(for: workout.workoutActivityType)
        name = sport
        date = DateFormatter.ymd.string(from: workout.startDate)
        durationMin = workout.duration / 60
        distanceKm = workout.totalDistance.map { $0.doubleValue(for: .meter()) / 1000 }
        avgHRbpm = nil  // HR requires a separate query
        totalEnergyKcal = workout.statistics(for: HKQuantityType(.activeEnergyBurned))?
            .sumQuantity()?.doubleValue(for: .kilocalorie())
    }

    private static func sportName(for type: HKWorkoutActivityType) -> String {
        switch type {
        case .running: return "Running"
        case .cycling: return "Cycling"
        case .swimming: return "Swimming"
        case .walking: return "Walking"
        case .hiking: return "Hiking"
        case .traditionalStrengthTraining, .functionalStrengthTraining: return "Strength"
        default: return "Workout"
        }
    }
}

struct HeartRateSample: Identifiable {
    let id = UUID()
    let date: Date
    let bpm: Double
}

// MARK: - Errors

enum HKServiceError: LocalizedError {
    case notAvailable

    var errorDescription: String? {
        "HealthKit is not available on this device."
    }
}
