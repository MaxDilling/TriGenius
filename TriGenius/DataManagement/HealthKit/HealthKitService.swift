import Foundation
import HealthKit
import CoreLocation

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
            HKQuantityType(.runningSpeed),
            HKQuantityType(.runningPower),
            HKQuantityType(.cyclingSpeed),
            HKQuantityType(.cyclingPower),
            HKQuantityType(.cyclingCadence),
            HKQuantityType(.swimmingStrokeCount),
            HKQuantityType(.oxygenSaturation),
            HKQuantityType(.respiratoryRate),
            HKQuantityType(.cyclingFunctionalThresholdPower),
            HKQuantityType(.vo2Max),
            HKQuantityType(.bodyMass),
            HKCategoryType(.sleepAnalysis),
            HKSeriesType.workoutRoute()
        ]

        try await store.requestAuthorization(toShare: [], read: readTypes)
        authorized = true
    }

    // MARK: - Recent Workouts

    /// `since` bounds the query to workouts on/after that date — used by the
    /// incremental sync so only new activities are fetched. Garmin-authored mirrors
    /// are dropped here (see `isGarmin`); the rich per-workout record is built by
    /// `normalizedRecord(for:hrZoneBounds:)`.
    func fetchWorkouts(count: Int = 10, since: Date? = nil) async throws -> [HKWorkout] {
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
                continuation.resume(returning: workouts)
            }
            store.execute(query)
        }
    }

    /// Recent workouts as scored-ready DTOs. Derives each workout's HR zone bounds
    /// from `history` (the athlete's thresholds as of that day) so a session without
    /// power/pace still gets a heart-rate TSS. The store scores TSS at ingest.
    func fetchActivities(count: Int = 10, since: Date? = nil,
                         history: PerformanceHistory) async throws -> [IngestedActivity] {
        let workouts = try await fetchWorkouts(count: count, since: since)
        var out: [IngestedActivity] = []
        for workout in workouts {
            let bounds = HRZones.upperBounds(snapshot: history.snapshot(asOf: workout.startDate))
            let rec = try await normalizedRecord(for: workout, hrZoneBounds: bounds)
            if let dto = Self.ingestDTO(from: rec) { out.append(dto) }
        }
        return out
    }

    /// Wrap a normalized record into an unscored `IngestedActivity` (mirrors
    /// `GarminService.ingestDTO`); the store computes TSS + effective distance from
    /// `detailsJSON` at ingest. Nil without an id/date.
    private static func ingestDTO(from rec: [String: Any]) -> IngestedActivity? {
        guard let id = rec["id"] as? String,
              let dateStr = rec["date"] as? String, let date = DateFormatter.ymd.date(from: dateStr) else { return nil }
        let detailsJSON = (try? JSONSerialization.data(withJSONObject: rec))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return IngestedActivity(
            id: "healthkit:\(id)",
            source: "healthkit",
            date: date,
            sport: rec["sport"] as? String ?? "unknown",
            name: rec["name"] as? String ?? "Activity",
            durationMinutes: (rec["duration_minutes"] as? NSNumber)?.doubleValue ?? 0,
            distanceKm: (rec["distance_km"] as? NSNumber)?.doubleValue ?? 0,
            aerobicTE: nil,
            anaerobicTE: nil,
            detailsJSON: detailsJSON
        )
    }

    // MARK: - Normalized per-workout record
    //
    // The HealthKit analogue of `GarminService.formatActivityRecord`: reads the rich
    // statistics + streams Apple Health stores (avg/max HR, cadence, power, speed,
    // elevation, time-in-zone, normalized power/pace) into the shared `detailsJSON`
    // schema the detail view and `TSSCalculator` consume. Brand-specific extraction
    // lives here, in the source layer — the store scores TSS from the result.
    //
    // `hrZoneBounds` (z1–z4 upper bpm, derived by the caller from the athlete's
    // thresholds for the activity's date) drives time-in-zone; pass nil to omit it.

    func normalizedRecord(for workout: HKWorkout, hrZoneBounds: [Double]?) async throws -> [String: Any] {
        let sport = Self.sportName(for: workout.workoutActivityType)
        let family = SportFamily(sportKey: sport)
        let durationMin = workout.duration / 60
        let distanceM = workout.totalDistance?.doubleValue(for: .meter())
        let bpm = HKUnit.count().unitDivided(by: .minute())
        let mps = HKUnit.meter().unitDivided(by: .second())
        let rpm = HKUnit.count().unitDivided(by: .minute())

        func avg(_ id: HKQuantityTypeIdentifier, _ unit: HKUnit) -> Double? {
            workout.statistics(for: HKQuantityType(id))?.averageQuantity()?.doubleValue(for: unit)
        }
        func peak(_ id: HKQuantityTypeIdentifier, _ unit: HKUnit) -> Double? {
            workout.statistics(for: HKQuantityType(id))?.maximumQuantity()?.doubleValue(for: unit)
        }
        func total(_ id: HKQuantityTypeIdentifier, _ unit: HKUnit) -> Double? {
            workout.statistics(for: HKQuantityType(id))?.sumQuantity()?.doubleValue(for: unit)
        }

        var data: [String: Any] = [
            "id": workout.uuid.uuidString,
            "name": sport,
            "date": DateFormatter.ymd.string(from: workout.startDate),
            "time": Self.clock.string(from: workout.startDate),
            "sport": sport,
            "duration_minutes": Self.round1(durationMin),
            "distance_km": distanceM.map { Self.round2($0 / 1000) } ?? NSNull(),
            "calories": total(.activeEnergyBurned, .kilocalorie()).map { Int($0.rounded()) } ?? NSNull(),
            "avg_hr": avg(.heartRate, bpm).map { Int($0.rounded()) } ?? NSNull(),
            "max_hr": peak(.heartRate, bpm).map { Int($0.rounded()) } ?? NSNull(),
        ]
        if let ascended = (workout.metadata?[HKMetadataKeyElevationAscended] as? HKQuantity)?
            .doubleValue(for: .meter()), ascended > 0 {
            data["elevation_gain_m"] = Int(ascended.rounded())
        }
        // Time-in-zone from the high-res HR stream + the athlete's zone bounds — the
        // input the HR-zone TSS fallback needs (and Garmin supplies directly).
        if let hrZoneBounds {
            let series = (try? await fetchHeartRateSeries(during: workout)) ?? []
            if let zones = HRZones.timeInZoneSeconds(series, upperBounds: hrZoneBounds) {
                data["hr_zones_seconds"] = zones
            }
        }

        switch family {
        case .run:
            var running: [String: Any] = [:]
            if let steps = total(.stepCount, .count()), durationMin > 0 {
                running["avg_cadence_spm"] = Int((steps / durationMin).rounded())
            }
            if let power = avg(.runningPower, .watt()) { running["avg_power_w"] = Int(power.rounded()) }
            // Normalized graded pace (sec/km) for rTSS — true NGP, from the running-speed
            // (or distance) stream grade-adjusted via the GPS route, through the shared
            // `GradeAdjustedPace` / `NormalizedStream`. Left absent when no usable stream
            // exists — never substituted with the average pace (that is a different
            // number, not a normalized one).
            if let normSpeed = try? await fetchNormalizedSpeed(during: workout), normSpeed > 0 {
                running["normalized_pace_s_per_km"] = Self.round1(1000.0 / normSpeed)
            }
            if !running.isEmpty { data["running"] = running }
        case .bike:
            var cycling: [String: Any] = [:]
            if let speed = avg(.cyclingSpeed, mps), speed > 0 { cycling["avg_speed_kmh"] = Self.round1(speed * 3.6) }
            if let speed = peak(.cyclingSpeed, mps), speed > 0 { cycling["max_speed_kmh"] = Self.round1(speed * 3.6) }
            if let power = avg(.cyclingPower, .watt()) { cycling["avg_power_w"] = Int(power.rounded()) }
            if let power = peak(.cyclingPower, .watt()) { cycling["max_power_w"] = Int(power.rounded()) }
            if let cadence = avg(.cyclingCadence, rpm) { cycling["avg_cadence_rpm"] = Int(cadence.rounded()) }
            // Normalized power for power-TSS, computed from the power stream when a
            // power meter recorded one; absent it, TSS falls back to HR zones.
            if let np = try? await fetchNormalizedPower(during: workout) {
                cycling["normalized_power_w"] = Int(np.rounded())
            }
            if !cycling.isEmpty { data["cycling"] = cycling }
        case .swim:
            var swimming: [String: Any] = [:]
            if let lap = (workout.metadata?[HKMetadataKeyLapLength] as? HKQuantity)?.doubleValue(for: .meter()), lap > 0 {
                swimming["pool_length_m"] = Self.round1(lap)
            }
            if let strokes = total(.swimmingStrokeCount, .count()) { swimming["total_strokes"] = Int(strokes.rounded()) }
            if let distanceM, distanceM > 0, durationMin > 0 {
                let secPer100 = (durationMin * 60) / (distanceM / 100)
                swimming["avg_pace_per_100m"] = String(format: "%d:%02d", Int(secPer100) / 60, Int(secPer100) % 60)
            }
            if !swimming.isEmpty { data["swimming"] = swimming }
        case .strength, .other:
            break
        }
        return data
    }

    /// Normalized power (W) from the cycling power stream, via the shared
    /// `NormalizedStream`. Each reading carries its own measurement interval, so the
    /// 30 s window is real time. Zeros are kept (coasting counts toward NP — the
    /// TrainingPeaks convention; unlike pace, where a stop is not "slow running").
    /// Nil when no usable power series exists (no power meter).
    private func fetchNormalizedPower(during workout: HKWorkout) async throws -> Double? {
        let series = try await quantityIntervalSeries(.cyclingPower, unit: .watt(), during: workout)
        return NormalizedStream.normalized(series.map { (value: $0.value, seconds: $0.duration) })
    }

    /// Normalized graded speed (m/s) for a run, via the shared `NormalizedStream`. Nil
    /// when no high-res signal exists (the caller then leaves the pace empty).
    private func fetchNormalizedSpeed(during workout: HKWorkout) async throws -> Double? {
        NormalizedStream.normalized(try await speedStream(during: workout).samples)
    }

    /// Provenance of a run's normalized pace, recomputed live for the debug export so
    /// the speed-stream inputs are attached to the exact workout (no log correlation).
    /// Run workouts only; nil otherwise.
    func speedStreamDiagnostics(forWorkoutID id: String) async -> [String: Any]? {
        guard let workout = try? await fetchWorkout(id: id),
              SportFamily(sportKey: Self.sportName(for: workout.workoutActivityType)) == .run,
              let stream = try? await speedStream(during: workout) else { return nil }
        var d = NormalizedStream.diagnostics(stream.samples)
        d["source"] = stream.source
        if let m = d["mean_value"] as? Double, m > 0 { d["mean_pace_s_per_km"] = Self.round1(1000.0 / m) }
        if let n = d["normalized_value"] as? Double, n > 0 { d["normalized_pace_s_per_km"] = Self.round1(1000.0 / n) }
        return d
    }

    /// Grade-adjusted moving-speed samples for a run — each speed reading (m/s) turned
    /// into its equivalent FLAT speed (`GradeAdjustedPace`, true NGP) and paired with
    /// the `seconds` of real time it covers (its own measurement interval) — plus which
    /// stream they came from: the device's running-speed series when present, else the
    /// distance series turned into per-interval speed. Both carry HealthKit's own
    /// per-sample interval, so the durations sum to MOVING time (the average's basis)
    /// and the normalizer's window is real seconds. The gradient at each sample comes
    /// from the GPS route (outdoor runs); without a route every grade is 0, so the
    /// result reduces to plain normalized speed. Stopped readings (≤ 0) are dropped: a
    /// running pace is over moving time, and counting paused time pulls the normalized
    /// speed below the moving average (impossible for a real normalized value). Empty
    /// when neither stream exists.
    private func speedStream(during workout: HKWorkout) async throws
        -> (source: String, samples: [NormalizedStream.Sample]) {
        let mps = HKUnit.meter().unitDivided(by: .second())
        let running = try await quantityIntervalSeries(.runningSpeed, unit: mps, during: workout)
            .filter { $0.duration > 0 && $0.value > 0 }
        let source: String
        let raw: [(start: Date, speed: Double, seconds: Double)]
        if !running.isEmpty {
            source = "runningSpeed"
            raw = running.map { (start: $0.start, speed: $0.value, seconds: $0.duration) }
        } else {
            // No speed series: per-interval speed from the distance stream (a paused
            // interval covers ~0 distance → ~0 speed → dropped by the same moving filter).
            source = "distanceWalkingRunning"
            raw = try await quantityIntervalSeries(.distanceWalkingRunning, unit: .meter(), during: workout)
                .filter { $0.duration > 0 && $0.value > 0 }
                .map { (start: $0.start, speed: $0.value / $0.duration, seconds: $0.duration) }
        }
        guard !raw.isEmpty else { return (source, []) }

        let grades = (try? await routeGradeSegments(during: workout)) ?? []
        let paired = raw.map {
            (speed: $0.speed, grade: Self.grade(at: $0.start, in: grades), seconds: $0.seconds)
        }
        return (source + (grades.isEmpty ? "" : "+route"), GradeAdjustedPace.adjusted(paired))
    }

    /// Per-segment gradient (rise/run, fraction) along the GPS route — each segment spans
    /// its two route points' timestamps and carries the de-noised
    /// `GradeAdjustedPace.smoothedGrades` value (central difference over a fixed horizontal
    /// span, not the raw point-to-point delta, which GPS/barometer noise would bias upward
    /// through the convex cost factor). Empty for indoor runs (no route).
    private func routeGradeSegments(during workout: HKWorkout) async throws -> [(start: Date, end: Date, grade: Double)] {
        let locations = try await routeLocations(during: workout).sorted { $0.timestamp < $1.timestamp }
        guard locations.count >= 2 else { return [] }
        var distance = [0.0]
        var altitude = [locations[0].altitude]
        for i in 1..<locations.count {
            distance.append(distance[i - 1] + locations[i].distance(from: locations[i - 1]))
            altitude.append(locations[i].altitude)
        }
        let grades = GradeAdjustedPace.smoothedGrades(distance: distance, altitude: altitude)
        return (1..<locations.count).map {
            (start: locations[$0 - 1].timestamp, end: locations[$0].timestamp, grade: grades[$0])
        }
    }

    /// Gradient of the route segment covering `time` (0 when none — e.g. a sample before
    /// the GPS lock). `segments` are sorted, non-overlapping; binary-search the last one
    /// starting at/before `time`.
    private static func grade(at time: Date, in segments: [(start: Date, end: Date, grade: Double)]) -> Double {
        guard !segments.isEmpty else { return 0 }
        var lo = 0, hi = segments.count - 1, found = -1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if segments[mid].start <= time { found = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        guard found >= 0, time <= segments[found].end else { return 0 }
        return segments[found].grade
    }

    /// The workout's GPS route as `CLLocation`s (altitude + timestamp), via the
    /// `workoutRoute` series sample. Empty when the workout has no route (indoor).
    private func routeLocations(during workout: HKWorkout) async throws -> [CLLocation] {
        let routes: [HKWorkoutRoute] = try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(sampleType: HKSeriesType.workoutRoute(),
                                      predicate: HKQuery.predicateForObjects(from: workout),
                                      limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, error in
                if let error { continuation.resume(throwing: error); return }
                continuation.resume(returning: (samples as? [HKWorkoutRoute]) ?? [])
            }
            store.execute(query)
        }
        guard let route = routes.first else { return [] }
        return try await withCheckedThrowingContinuation { continuation in
            var collected: [CLLocation] = []
            var didResume = false
            let query = HKWorkoutRouteQuery(route: route) { _, locations, done, error in
                if let error {
                    if !didResume { didResume = true; continuation.resume(throwing: error) }
                    return
                }
                if let locations { collected.append(contentsOf: locations) }
                if done, !didResume { didResume = true; continuation.resume(returning: collected) }
            }
            store.execute(query)
        }
    }

    /// Like `quantitySeries`, but keeps each point's interval duration — needed to
    /// turn an accumulating quantity (distance per interval) into a rate (speed).
    ///
    /// Scoped to the workout's OWN samples (`predicateForObjects(from:)`), not every
    /// sample in its time window: a second paired device recording the same run writes
    /// its own overlapping series, and a plain time-range query would sum both, so the
    /// durations exceed the real moving time and the normalized value collapses. Falls
    /// back to the time range for older/third-party workouts that don't associate their
    /// samples with the workout (else the scoped query is empty).
    private func quantityIntervalSeries(_ id: HKQuantityTypeIdentifier, unit: HKUnit,
                                        during workout: HKWorkout) async throws -> [(start: Date, duration: TimeInterval, value: Double)] {
        let scoped = try await intervalSeries(id, unit: unit, predicate: HKQuery.predicateForObjects(from: workout))
        if !scoped.isEmpty { return scoped }
        return try await intervalSeries(id, unit: unit,
                                        predicate: HKQuery.predicateForSamples(withStart: workout.startDate, end: workout.endDate))
    }

    private func intervalSeries(_ id: HKQuantityTypeIdentifier, unit: HKUnit,
                                predicate: NSPredicate) async throws -> [(start: Date, duration: TimeInterval, value: Double)] {
        let type = HKQuantityType(id)
        return try await withCheckedThrowingContinuation { continuation in
            var collected: [(start: Date, duration: TimeInterval, value: Double)] = []
            var didResume = false
            let query = HKQuantitySeriesSampleQuery(quantityType: type, predicate: predicate) {
                _, quantity, dateInterval, _, done, error in
                if let error {
                    if !didResume { didResume = true; continuation.resume(throwing: error) }
                    return
                }
                if let quantity, let dateInterval {
                    collected.append((dateInterval.start, dateInterval.duration, quantity.doubleValue(for: unit)))
                }
                if done, !didResume {
                    didResume = true
                    continuation.resume(returning: collected)
                }
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

    /// High-resolution HR stream for a workout, via `HKQuantitySeriesSampleQuery` —
    /// the same beat-to-beat series the CSV export and Apple Health show (≈ 1 s),
    /// not the ≈ 2.5 min aggregated samples a plain `HKSampleQuery` returns. Backs
    /// both the detail chart and the time-in-zone bucketing.
    func fetchHeartRateSeries(during workout: HKWorkout) async throws -> [HeartRateSample] {
        let unit = HKUnit.count().unitDivided(by: HKUnit.minute())
        return try await quantitySeries(.heartRate, unit: unit, during: workout)
            .map { HeartRateSample(date: $0.date, bpm: $0.value) }
    }

    /// Enumerates the high-resolution data points stored *inside* each sample of a
    /// quantity series for the workout's interval (HR, power, …). Each point is
    /// timestamped at its interval start.
    private func quantitySeries(_ id: HKQuantityTypeIdentifier, unit: HKUnit,
                                during workout: HKWorkout) async throws -> [(date: Date, value: Double)] {
        let type = HKQuantityType(id)
        let predicate = HKQuery.predicateForSamples(withStart: workout.startDate, end: workout.endDate)
        return try await withCheckedThrowingContinuation { continuation in
            var collected: [(date: Date, value: Double)] = []
            var didResume = false
            let query = HKQuantitySeriesSampleQuery(quantityType: type, predicate: predicate) {
                _, quantity, dateInterval, _, done, error in
                if let error {
                    if !didResume { didResume = true; continuation.resume(throwing: error) }
                    return
                }
                if let quantity, let dateInterval {
                    collected.append((dateInterval.start, quantity.doubleValue(for: unit)))
                }
                if done, !didResume {
                    didResume = true
                    continuation.resume(returning: collected)
                }
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

    // MARK: - Formatting helpers

    /// Local wall-clock `HH:mm` of the workout start — parsed back into `startMinute`
    /// by the store (`clockMinute(fromDetails:)`), mirroring Garmin's `time` field.
    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }()

    private static func round1(_ v: Double) -> Double { (v * 10).rounded() / 10 }
    private static func round2(_ v: Double) -> Double { (v * 100).rounded() / 100 }

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

// MARK: - Data Models

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
