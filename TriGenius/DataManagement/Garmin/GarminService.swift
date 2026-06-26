import Foundation
import os

// MARK: - Garmin Service
//
// High-level orchestration ported from TriGenius_python/garmin/service.py.
// Each public method returns a ToolResult-style JSON string for the coach,
// except `syncUserSettings` which also returns the parsed settings dict so the
// caller can persist them into CoachMemory (as the Python CLI does).

actor GarminService {

    static let shared = GarminService()
    private let client = GarminClient.shared
    private let log = Logger(subsystem: "net.Narica.TriGenius", category: "Garmin")
    private init() {}

    // MARK: - Result helpers

    /// JSON-safe value: the wrapped value, or NSNull when nil.
    private func orNull(_ v: Any?) -> Any { if let v { return v }; return NSNull() }
    private func round1(_ v: Double) -> Double { (v * 10).rounded() / 10 }
    private func round2(_ v: Double) -> Double { (v * 100).rounded() / 100 }

    /// `{z1…z5: seconds}` from per-zone keys like `hrTimeInZone_1` (rounded to Int).
    private func zoneSeconds(_ source: [String: Any], prefix: String) -> [String: Int] {
        var out: [String: Int] = [:]
        for i in 1...5 { out["z\(i)"] = Int((Coerce.double(source["\(prefix)_\(i)"]) ?? 0).rounded()) }
        return out
    }

    /// `{z1…z5: [lo, hi]}` from six ascending bounds (z1 floor … top cap).
    private func zoneBands(_ bounds: [Int]) -> [String: [Int]] {
        var out: [String: [Int]] = [:]
        for i in 0..<5 { out["z\(i + 1)"] = [bounds[i], bounds[i + 1]] }
        return out
    }

    private func resultString(success: Bool, data: Any?, message: String) -> String {
        if !success { return "✗ Error: \(message)" }
        let json = data.map { String(prettyJSON: $0) } ?? ""
        return "✓ \(message)\n\(json)"
    }

    private func authMessage(_ error: Error) -> String {
        if let g = error as? GarminAuthError { return g.errorDescription ?? "\(error)" }
        return "\(error)"
    }

    // MARK: - Activity formatting

    private func activityTypeToSport(_ id: Int?) -> String? {
        guard let id else { return nil }
        return GarminMappings.activityTypeToSport[id] ?? "other"
    }

    private func formatActivityRecord(_ activity: [String: Any]) async -> [String: Any] {
        let startTime = activity["startTimeLocal"] as? String ?? ""
        let activityType = (activity["activityType"] as? [String: Any])?["typeKey"] as? String ?? "unknown"

        func intOrNull(_ key: String) -> Any { Coerce.double(activity[key]).map { Int($0.rounded()) } ?? NSNull() }

        var data: [String: Any] = [
            "id": activity["activityId"] ?? NSNull(),
            "name": activity["activityName"] as? String ?? "Activity",
            "date": startTime.count >= 10 ? String(startTime.prefix(10)) : "",
            "time": startTime.count > 11 ? String(startTime.dropFirst(11).prefix(5)) : "",
            "sport": activityType,
            "duration_minutes": round1((Coerce.double(activity["duration"]) ?? 0) / 60),
            "distance_km": round2((Coerce.double(activity["distance"]) ?? 0) / 1000),
            "calories": activity["calories"] ?? NSNull(),
            "location": activity["locationName"] ?? NSNull(),
            "avg_hr": intOrNull("averageHR"),
            "max_hr": intOrNull("maxHR"),
            "aerobic_te": Coerce.double(activity["aerobicTrainingEffect"]).map { round1($0) } ?? NSNull(),
            "anaerobic_te": Coerce.double(activity["anaerobicTrainingEffect"]).map { round1($0) } ?? NSNull(),
            "training_load": intOrNull("activityTrainingLoad"),
            "elevation_gain_m": intOrNull("elevationGain"),
            "elevation_loss_m": intOrNull("elevationLoss")
        ]
        if activity["hrTimeInZone_1"] != nil {
            data["hr_zones_seconds"] = zoneSeconds(activity, prefix: "hrTimeInZone")
        }

        // Athlete's subjective post-workout feedback, mirroring Garmin's "How did
        // you feel?" / perceived-effort prompt. Garmin stores feel as 0/25/50/75/100
        // → mapped to a 1–5 scale, and RPE as 0–100 (×10) → a 1–10 scale. A local
        // edit via log_workout_feedback overwrites these same keys.
        // NOTE: validate `workoutFeel`/`workoutRpe`/`description` against a real
        // synced activity — these are the documented Garmin activity DTO keys.
        if let feel = Self.mappedFeel(activity["workoutFeel"]) { data["feel"] = feel }
        if let rpe = Self.mappedRpe(activity["workoutRpe"]) { data["rpe"] = rpe }
        if let desc = (activity["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !desc.isEmpty {
            data["notes"] = desc
        }

        if ["running", "trail_running", "treadmill_running"].contains(activityType) {
            var running: [String: Any] = [
                "avg_pace_min_km": orNull(GarminTransform.speedToPace(Coerce.double(activity["averageSpeed"]), distanceM: 1000)),
                "best_pace_min_km": orNull(GarminTransform.speedToPace(Coerce.double(activity["maxSpeed"]), distanceM: 1000)),
                "avg_cadence_spm": orNull(Coerce.double(activity["averageRunningCadenceInStepsPerMinute"]).map { Int($0.rounded()) }),
                "max_cadence_spm": orNull(Coerce.double(activity["maxRunningCadenceInStepsPerMinute"]).map { Int($0.rounded()) }),
                "avg_power_w": orNull(Coerce.double(activity["avgPower"]).map { Int($0.rounded()) }),
                "steps": orNull(activity["steps"])
            ]
            // Normalized pace (sec/km) for rTSS — NGS from the 1 Hz speed stream,
            // falling back to average speed. Grade ignored (future NGP, FEATURES.md).
            // Only runs for NEW activities (callers gate on the activity cache).
            let avgSpeed = Coerce.double(activity["averageSpeed"]) ?? 0
            var normPaceSecPerKm: Double? = avgSpeed > 0 ? 1000.0 / avgSpeed : nil
            if let activityId = activity["activityId"].map({ "\($0)" }),
               let details = try? await client.getActivityDetails(id: activityId),
               let ngs = GarminTransform.normalizedSpeedMps(details), ngs > 0 {
                normPaceSecPerKm = 1000.0 / ngs
            }
            running["normalized_pace_s_per_km"] = normPaceSecPerKm.map { round1($0) } ?? NSNull()
            data["running"] = running
        } else if ["cycling", "indoor_cycling", "virtual_ride"].contains(activityType) {
            let avgSpeed = Coerce.double(activity["averageSpeed"]) ?? 0
            var cycling: [String: Any] = [
                "avg_speed_kmh": avgSpeed > 0 ? round1(avgSpeed * 3.6) : NSNull(),
                "max_speed_kmh": Coerce.double(activity["maxSpeed"]).map { round1($0 * 3.6) } ?? NSNull(),
                "avg_power_w": Coerce.double(activity["avgPower"]).map { Int($0.rounded()) } ?? NSNull(),
                "max_power_w": Coerce.double(activity["maxPower"]).map { Int($0.rounded()) } ?? NSNull(),
                "normalized_power_w": Coerce.double(activity["normPower"]).map { Int($0.rounded()) } ?? NSNull(),
                "avg_cadence_rpm": Coerce.double(activity["avgBikingCadenceInRevPerMinute"]).map { Int($0.rounded()) } ?? NSNull()
            ]
            if activity["powerTimeInZone_1"] != nil {
                cycling["power_zones_seconds"] = zoneSeconds(activity, prefix: "powerTimeInZone")
            }
            data["cycling"] = cycling
        } else if activityType.lowercased().contains("swim") {
            let poolLengthM = Coerce.double(activity["poolLength"]).map { $0 / 100 }
            let activityId = activity["activityId"].map { "\($0)" }
            var intervals: [[String: Any]]? = nil
            var lengths: [[String: Any]] = []
            if let activityId {
                if let splits = try? await client.getActivitySplits(id: activityId),
                   let lapDTOs = splits["lapDTOs"] as? [[String: Any]], !lapDTOs.isEmpty {
                    let built = GarminTransform.buildSwimIntervals(lapDTOs, poolLengthM: poolLengthM)
                    intervals = built.isEmpty ? nil : built
                    // Store the per-length data so SwimLengthCleaner can rejoin Garmin's
                    // over-counted lengths — at ingest (via TSSScoring) and on recompute.
                    lengths = GarminTransform.activeSwimLengths(lapDTOs).map {
                        ["d": round1($0.durationSeconds), "s": $0.strokes, "m": $0.distanceMeters]
                    }
                }
            }
            let avgPace100 = GarminTransform.speedToPace(Coerce.double(activity["averageSpeed"]), distanceM: 100)
            let garminDistanceM = Coerce.double(activity["distance"]).map { round1($0) }
            var swimming: [String: Any] = [
                "pool_length_m": poolLengthM ?? NSNull(),
                "avg_swolf": activity["averageSwolf"] ?? NSNull(),
                "avg_strokes_per_length": activity["avgStrokes"] ?? NSNull(),
                "total_lengths": activity["activeLengths"] ?? NSNull(),
                "intervals": intervals ?? NSNull()
            ]
            swimming["avg_pace_per_100m"] = avgPace100 ?? NSNull()
            swimming["garmin_distance_m"] = garminDistanceM ?? NSNull()
            swimming["lengths"] = lengths.isEmpty ? NSNull() : lengths
            data["swimming"] = swimming
            // Effective distance + sTSS are resolved by the store at ingest
            // (`TrainingDataStore.ingest` → `TSSScoring.score`).
        }
        return data
    }

    /// Garmin feel buckets (0/25/50/75/100) → 1–5. Nil when not rated.
    private static func mappedFeel(_ raw: Any?) -> Int? {
        guard let v = Coerce.double(raw) else { return nil }
        return min(5, max(1, Int((v / 25).rounded()) + 1))
    }

    /// Garmin RPE (0–100, i.e. RPE ×10) → 1–10. Nil/0 means not rated.
    private static func mappedRpe(_ raw: Any?) -> Int? {
        guard let v = Coerce.double(raw), v > 0 else { return nil }
        return min(10, max(1, Int((v / 10).rounded())))
    }

    /// Build the local-DB ingest snapshot from a *formatted* coach record. Stores
    /// the full normalized record as `detailsJSON` (so `get_activities` can serve it
    /// verbatim); TSS + the effective distance are computed by the store at ingest
    /// (`TrainingDataStore.ingest`), scored against the activity's own date. Returns
    /// nil without an id/date.
    private func ingestDTO(from rec: [String: Any]) -> IngestedActivity? {
        guard let idNum = rec["id"] as? NSNumber else { return nil }
        guard let dateStr = rec["date"] as? String, let date = GarminTransform.date(from: dateStr) else { return nil }
        let detailsJSON = (try? JSONSerialization.data(withJSONObject: rec))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return IngestedActivity(
            id: "garmin:\(idNum.intValue)",
            source: "garmin",
            date: date,
            sport: rec["sport"] as? String ?? "unknown",
            name: rec["name"] as? String ?? "Activity",
            durationMinutes: (rec["duration_minutes"] as? NSNumber)?.doubleValue ?? 0,
            distanceKm: (rec["distance_km"] as? NSNumber)?.doubleValue ?? 0,
            aerobicTE: (rec["aerobic_te"] as? NSNumber)?.doubleValue,
            anaerobicTE: (rec["anaerobic_te"] as? NSNumber)?.doubleValue,
            detailsJSON: detailsJSON
        )
    }

    // MARK: - get_activities

    func getActivities(sport: String?, count: Int = 10, days: Int?) async -> String {
        do {
            let fetchCount = sport != nil ? count * 3 : count
            let raw = try await client.getActivities(start: 0, limit: min(fetchCount, 100))
            // Cutoff at the start of the day so `days: 1` keeps all of yesterday
            // (and today), not just the last 24h from now. See DataSyncCoordinator.
            let cutoff: Date? = days.map {
                Calendar.current.date(byAdding: .day, value: -$0, to: Calendar.current.startOfDay(for: Date()))!
            }
            let targetIDs = sport.flatMap { GarminMappings.sportFilterIDs[$0.lowercased()] }

            // Cache: reuse already-stored activities verbatim; only NEW workouts pay
            // the extra stream/splits fetch. TSS is scored by the store at ingest.
            let candidateIDs = Set(raw.compactMap { ($0["activityId"] as? NSNumber).map { "garmin:\($0.intValue)" } })
            let cache = await TrainingDataStore.shared.cachedActivities(ids: candidateIDs)

            var formatted: [[String: Any]] = []
            var toIngest: [IngestedActivity] = []
            for activity in raw {
                if let targetIDs, let sid = (activity["sportTypeId"] as? NSNumber)?.intValue, !targetIDs.contains(sid) {
                    continue
                }
                let startTime = activity["startTimeLocal"] as? String ?? ""
                if let cutoff, startTime.count >= 10, let aDate = GarminTransform.date(from: String(startTime.prefix(10))), aDate < cutoff {
                    continue
                }
                let gid = (activity["activityId"] as? NSNumber).map { "garmin:\($0.intValue)" }
                if let gid, let cached = cache[gid],
                   let cachedData = cached.detailsJSON.data(using: .utf8),
                   let cachedRec = (try? JSONSerialization.jsonObject(with: cachedData)) as? [String: Any] {
                    formatted.append(cachedRec)            // already stored & computed
                } else {
                    let rec = await formatActivityRecord(activity)
                    formatted.append(rec)
                    if let dto = ingestDTO(from: rec) { toIngest.append(dto) }
                }
                if formatted.count >= count { break }
            }

            // Persist into the local time-series database (GOAL.md step 1).
            await TrainingDataStore.shared.ingest(toIngest)

            var data: [String: Any] = [
                "activities": formatted,
                "count": formatted.count,
                "summary": GarminTransform.calculateActivitySummary(formatted)
            ]
            data["filter"] = (sport != nil || days != nil) ? ["sport": sport as Any, "days": days as Any] : NSNull()
            return resultString(success: true, data: data, message: "Retrieved \(formatted.count) \(sport ?? "all") activities")
        } catch {
            return resultString(success: false, data: nil, message: "Failed to fetch activities: \(authMessage(error))")
        }
    }

    // MARK: - Deep history backfill
    //
    // CTL (Fitness, 42-day EWMA) needs a long warm-up to be reliable; the regular
    // incremental sync only keeps recently-synced activities. This pulls a whole
    // date range (paginated, not capped at 100) into the local database to give
    // the PMC engine a proper warm-up. Returns the number of activities ingested,
    // or nil on failure. FEATURES.md "Deeper Garmin history backfill".
    /// `force` re-fetches & recomputes even already-stored activities (the
    /// "recompute all" path); otherwise stored activities are skipped (the cache).
    func backfillActivities(startDate: String, endDate: String, force: Bool = false) async -> Int? {
        do {
            let raw = try await client.getActivitiesByDate(start: startDate, end: endDate)
            let candidateIDs = Set(raw.compactMap { ($0["activityId"] as? NSNumber).map { "garmin:\($0.intValue)" } })
            let cache = await TrainingDataStore.shared.cachedActivities(ids: candidateIDs)
            var toIngest: [IngestedActivity] = []
            for activity in raw {
                let gid = (activity["activityId"] as? NSNumber).map { "garmin:\($0.intValue)" }
                if !force, let gid, cache[gid] != nil { continue }   // cache: skip known
                var rec = await formatActivityRecord(activity)
                // Preserve a prior manual distance override across a forced re-fetch.
                if let gid, let cached = cache[gid],
                   let data = cached.detailsJSON.data(using: .utf8),
                   let prior = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["manual_distance_m"] {
                    rec["manual_distance_m"] = prior
                }
                // TSS + effective distance are scored by the store at ingest.
                if let dto = ingestDTO(from: rec) { toIngest.append(dto) }
            }
            await TrainingDataStore.shared.ingest(toIngest)
            return toIngest.count
        } catch {
            return nil
        }
    }

    // MARK: - get_power_curve

    func getPowerCurve(startDate: String, endDate: String, sport: String = "cycling", durationsSeconds: [Int]?) async -> String {
        let sportKey = Coerce.token(sport, default: "cycling")
        if sportKey != "cycling" {
            return resultString(success: false, data: nil, message: "Power curve analysis is currently supported only for cycling.")
        }
        let start = GarminTransform.formatDate(startDate)
        let end = GarminTransform.formatDate(endDate)
        guard let startD = GarminTransform.date(from: start), let endD = GarminTransform.date(from: end) else {
            return resultString(success: false, data: nil, message: "Invalid date format. Use YYYY-MM-DD.")
        }
        if startD > endD {
            return resultString(success: false, data: nil, message: "start_date must be on or before end_date.")
        }
        let durations = Array(Set((durationsSeconds ?? GarminMappings.cyclingPowerCurveDurations).filter { $0 > 0 })).sorted()
        if durations.isEmpty {
            return resultString(success: false, data: nil, message: "durations_seconds must contain at least one positive integer.")
        }

        do {
            let targetIDs = GarminMappings.sportFilterIDs[sportKey] ?? []
            let rawActivities = try await client.getActivitiesByDate(start: start, end: end)
            let activities: [(id: String, name: String, date: String)] = rawActivities.compactMap { a in
                let st = a["startTimeLocal"] as? String ?? ""
                guard st.count >= 10 else { return nil }
                if !targetIDs.isEmpty, let sid = (a["sportTypeId"] as? NSNumber)?.intValue, !targetIDs.contains(sid) { return nil }
                guard let id = a["activityId"].map({ "\($0)" }) else { return nil }
                return (id, a["activityName"] as? String ?? "Activity", String(st.prefix(10)))
            }
            if activities.isEmpty {
                return resultString(success: false, data: nil, message: "No \(sportKey) activities found between \(start) and \(end).")
            }

            var bestCurve: [Int: [String: Any]] = [:]
            var activitiesWithPower = 0
            for activity in activities {
                var detail = try await client.getActivityDetails(id: activity.id, maxChart: 20000, maxPoly: 0)
                let total = (detail["totalMetricsCount"] as? NSNumber)?.intValue ?? 0
                let metricsCount = (detail["metricsCount"] as? NSNumber)?.intValue ?? 0
                if total > 0, metricsCount > 0, metricsCount < total {
                    detail = try await client.getActivityDetails(id: activity.id, maxChart: total, maxPoly: 0)
                }
                let segments = GarminTransform.extractPowerSegments(detail)
                if segments.isEmpty { continue }
                activitiesWithPower += 1
                for segment in segments {
                    for (duration, power) in GarminTransform.bestRollingAverages(segment, durations: durations) {
                        if let existing = bestCurve[duration], let p = existing["power_w"] as? Int, Double(p) >= power { continue }
                        bestCurve[duration] = [
                            "duration_seconds": duration,
                            "duration_label": GarminTransform.formatDurationLabel(duration),
                            "power_w": Int(power.rounded()),
                            "activity_id": activity.id,
                            "activity_name": activity.name,
                            "activity_date": activity.date
                        ]
                    }
                }
            }
            if bestCurve.isEmpty {
                return resultString(success: false, data: nil, message: "No cycling power samples found between \(start) and \(end).")
            }
            let curve = durations.compactMap { bestCurve[$0] }
            let data: [String: Any] = [
                "sport": sportKey,
                "period": ["start": start, "end": end],
                "durations_seconds": durations,
                "curve": curve,
                "activities_analyzed": activities.count,
                "activities_with_power_data": activitiesWithPower,
                "data_source": "activity_details.directPower"
            ]
            return resultString(success: true, data: data, message: "Computed cycling power curve from \(activitiesWithPower) activities")
        } catch {
            return resultString(success: false, data: nil, message: "Failed to compute power curve: \(authMessage(error))")
        }
    }

    // MARK: - fetchMetricHistory (wellness + performance range endpoints)
    //
    // One range call per metric type (no per-day looping) → a flat list of dated
    // samples for the local time-series DB (`MetricKeys.wellness` +
    // `MetricKeys.performance`). Best-effort: any endpoint that fails contributes
    // nothing. Parsing lives in `GarminTransform`; this maps each list onto a
    // metric key + unit. Speeds (CSS, LT) are stored raw in m/s — pace is a
    // display transform applied later (see `TrainingDataStore.latestSnapshot`).
    func fetchMetricHistory(startDate: String, endDate: String) async -> [IngestedMetric] {
        // Threshold endpoints share the daily/LATEST/running aggregation.
        let thresholdQuery = [("aggregation", "daily"), ("aggregationStrategy", "LATEST"), ("sport", "RUNNING")]

        // Independent range calls fire concurrently. `get` flattens the throwing
        // optional so a single failure just yields nil.
        async let hrvRaw      = get("/hrv-service/hrv/daily/\(startDate)/\(endDate)")
        async let sleepRows   = fetchSleepStats(startDate: startDate, endDate: endDate)
        async let weightRaw   = get("/weight-service/weight/range/\(startDate)/\(endDate)", query: [("includeAll", "true")])
        async let vo2Raw      = get("/metrics-service/metrics/maxmet/weekly/\(startDate)/\(endDate)")
        async let ftpRaw      = get("/biometric-service/stats/functionalThresholdPower/range/\(startDate)/\(endDate)", query: [("aggregation", "weekly")])
        async let cssRaw      = get("/biometric-service/criticalSwimSpeed/range/\(startDate)/\(endDate)")
        async let lthrRaw     = get("/biometric-service/stats/lactateThresholdHeartRate/range/\(startDate)/\(endDate)", query: thresholdQuery)
        async let ltSpeedRaw  = get("/biometric-service/stats/lactateThresholdSpeed/range/\(startDate)/\(endDate)", query: thresholdQuery)

        let hrvObj     = await hrvRaw as? [String: Any]
        let sleepObj   = await sleepRows
        let weightObj  = await weightRaw as? [String: Any]
        let vo2Arr     = await vo2Raw as? [[String: Any]]
        let ftpArr     = await ftpRaw as? [[String: Any]]
        let cssObj     = await cssRaw as? [String: Any]
        let lthrArr    = await lthrRaw as? [[String: Any]]
        let ltSpeedArr = await ltSpeedRaw as? [[String: Any]]

        var out: [IngestedMetric] = []
        func add(_ key: String, _ unit: String, _ samples: [GarminTransform.DatedValue]) {
            for s in samples {
                out.append(IngestedMetric(metricKey: key, value: s.value, unit: unit, source: "garmin", date: s.date))
            }
        }
        // Wellness — sleep (score, duration, the four stage durations) and the
        // night's resting HR all come from the one sleep-stats range payload.
        add("hrv_overnight", "ms", GarminTransform.parseHrvOvernight(hrvObj))
        let sleep = GarminTransform.parseSleepStats(sleepObj)
        add("sleep_score", "score", sleep["sleep_score"] ?? [])
        add("sleep_duration_h", "hours", sleep["sleep_duration_h"] ?? [])
        add("sleep_deep_h", "hours", sleep["sleep_deep_h"] ?? [])
        add("sleep_light_h", "hours", sleep["sleep_light_h"] ?? [])
        add("sleep_rem_h", "hours", sleep["sleep_rem_h"] ?? [])
        add("sleep_awake_h", "hours", sleep["sleep_awake_h"] ?? [])
        add("resting_hr", "bpm", sleep["resting_hr"] ?? [])
        // Performance
        add("weight_kg", "kg", GarminTransform.parseWeightKg(weightObj))
        add("vo2max_running", "ml_kg_min", GarminTransform.parseVo2Max(vo2Arr, subKey: "generic"))
        add("vo2max_cycling", "ml_kg_min", GarminTransform.parseVo2Max(vo2Arr, subKey: "cycling"))
        add("cycling_ftp", "watts", GarminTransform.parseFtp(ftpArr, series: "cycling"))
        add("running_ftp", "watts", GarminTransform.parseFtp(ftpArr, series: "running"))
        add("swim_css_speed", "m_per_s", GarminTransform.parseCssSpeed(cssObj))
        add("lactate_threshold_hr", "bpm", GarminTransform.parseThresholdHR(lthrArr))
        add("lactate_threshold_speed", "m_per_s", GarminTransform.parseThresholdSpeed(ltSpeedArr))
        return out
    }

    /// Issue a GET and flatten the throwing optional → a single failure yields nil.
    /// Logs the underlying error first so a swallowed range failure (e.g. the
    /// sleep endpoint's "Exceeded max number of days") is still visible in the
    /// unified log rather than silently leaving a metric un-backfilled.
    private func get(_ path: String, query: [(String, String)] = []) async -> Any? {
        do {
            return try await client.connectapi(path, query: query)
        } catch {
            log.error("GET \(path, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Sleep-stats range fetch, returned in the `{ "individualStats": [...] }`
    /// envelope `GarminTransform.parseSleepStats` expects. Unlike the other metric
    /// ranges (HRV, weight, biometric thresholds) this endpoint rejects windows
    /// over 28 days with `BadRequestException: Exceeded max number of days`, so a
    /// deep backfill must be split into ≤28-day chunks and their per-day rows
    /// merged — otherwise the whole sleep / resting-HR history is silently dropped.
    private func fetchSleepStats(startDate: String, endDate: String) async -> [String: Any]? {
        let windows = Self.dateWindows(startDate: startDate, endDate: endDate, maxDays: 28)
        // Fire the chunk requests concurrently; row order is irrelevant since the
        // transform keys each row by its own `calendarDate`.
        let chunks = await withTaskGroup(of: [[String: Any]].self) { group -> [[String: Any]] in
            for (start, end) in windows {
                group.addTask {
                    let obj = await self.get("/sleep-service/stats/sleep/daily/\(start)/\(end)") as? [String: Any]
                    return obj?["individualStats"] as? [[String: Any]] ?? []
                }
            }
            return await group.reduce(into: []) { $0.append(contentsOf: $1) }
        }
        return chunks.isEmpty ? nil : ["individualStats": chunks]
    }

    /// Split an inclusive `[startDate, endDate]` calendar range (both `yyyy-MM-dd`)
    /// into consecutive windows of at most `maxDays` days each, for endpoints that
    /// cap the per-request range. Returns `[(start, end)]` pairs as `yyyy-MM-dd`.
    static func dateWindows(startDate: String, endDate: String, maxDays: Int) -> [(String, String)] {
        let cal = Calendar.current
        guard maxDays > 0,
              let start = DateFormatter.ymd.date(from: startDate),
              let end = DateFormatter.ymd.date(from: endDate),
              start <= end else { return [(startDate, endDate)] }

        var windows: [(String, String)] = []
        var cursor = start
        while cursor <= end {
            // `maxDays - 1`: an inclusive window of N days spans N-1 day steps.
            let chunkEnd = min(cal.date(byAdding: .day, value: maxDays - 1, to: cursor) ?? end, end)
            windows.append((DateFormatter.ymd.string(from: cursor), DateFormatter.ymd.string(from: chunkEnd)))
            guard let next = cal.date(byAdding: .day, value: 1, to: chunkEnd) else { break }
            cursor = next
        }
        return windows
    }

    // MARK: - get_workouts

    func getWorkouts(startDate: String, endDate: String) async -> String {
        let start = GarminTransform.formatDate(startDate)
        let end = GarminTransform.formatDate(endDate)

        // `scheduled` holds editable planned workouts (round-trippable into
        // modify_workout); `completed` holds finished activities. Kept separate so
        // the model never has to filter a mixed list.
        var scheduled: [[String: Any]] = []
        var completed: [[String: Any]] = []
        var seen = Set<String>()

        // Calendar items across every month the window spans — Garmin's calendar
        // endpoint is per-month, so a window crossing a boundary (the default
        // look-ahead does) needs one call per month or the other month's items are
        // lost. A failed fetch must surface as an error, never an empty result:
        // `syncScheduledWorkouts` mirrors this list verbatim, so a silent empty
        // would wipe every planned workout (see BUGS.md).
        var calendarItems: [[String: Any]] = []
        do {
            for (year, month) in Self.monthsSpanned(start: start, end: end) {
                let calData = try await client.connectapi("/calendar-service/year/\(year)/month/\(month - 1)") as? [String: Any]
                calendarItems += calData?["calendarItems"] as? [[String: Any]] ?? []
            }
        } catch {
            return resultString(success: false, data: nil, message: "Failed to fetch calendar: \(authMessage(error))")
        }
        for item in calendarItems {
            let itemDate = item["date"] as? String ?? ""
            guard !itemDate.isEmpty, itemDate >= start, itemDate <= end else { continue }
            let itemType = item["itemType"] as? String
            if itemType == "workout", let workoutId = item["workoutId"] {
                let id = "\(workoutId)"
                if seen.contains(id) { continue }
                seen.insert(id)
                var durationMinutes: Any = NSNull()
                var steps: [[String: Any]] = []
                var poolLengthM: Any = NSNull()
                let sportKey = item["sportTypeKey"] as? String ?? "other"
                // Prefer the schedule detail: it embeds the same `workout`
                // payload AND the `associatedActivityId` Garmin sets once the
                // session is completed (used to suppress the redundant plan).
                // Fall back to the plain workout detail if no schedule id.
                var associatedActivityId: Any?
                let scheduleId = item["id"].map { "\($0)" }
                var details: [String: Any]?
                if let scheduleId, let schedule = try? await client.getScheduledWorkout(scheduleId: scheduleId) {
                    details = schedule["workout"] as? [String: Any]
                    associatedActivityId = schedule["associatedActivityId"].flatMap { $0 is NSNull ? nil : $0 }
                }
                if details == nil { details = try? await client.getWorkoutDetails(workoutId: id) }
                if let details {
                    if let est = Coerce.double(details["estimatedDurationInSecs"]) {
                        durationMinutes = Int((est / 60).rounded())
                    }
                    steps = compactSteps(fromDetails: details, sport: sportKey)
                    // Workout payloads store poolLength already in meters
                    // (unlike activity summaries, which use cm) — expose as-is.
                    if let pool = Coerce.double(details["poolLength"]), pool > 0 {
                        poolLengthM = pool
                    }
                }
                // workout_data mirrors the add_workouts/modify_workout shape, so
                // an item can be passed straight back to modify_workout.
                var entry: [String: Any] = [
                    "workout_id": id, "date": itemDate, "editable": true,
                    "workout_data": [
                        "name": item["title"] as? String ?? "Scheduled Workout",
                        "sport": sportKey, "duration_minutes": durationMinutes,
                        "description": "", "steps": steps, "pool_length": poolLengthM
                    ]
                ]
                if let associatedActivityId { entry["associated_activity_id"] = "\(associatedActivityId)" }
                scheduled.append(entry)
            } else if itemType == "activity" {
                let id = item["id"].map { "\($0)" } ?? ""
                if id.isEmpty || seen.contains(id) { continue }
                seen.insert(id)
                let elapsed = Coerce.double(item["elapsedDuration"])
                let durMs = Coerce.double(item["duration"])
                let durationMinutes: Any = elapsed.map { Int(($0 / 60).rounded()) }
                    ?? durMs.map { Int(($0 / 60000).rounded()) } ?? NSNull()
                let sport = item["sportTypeKey"] as? String ?? activityTypeToSport((item["activityTypeId"] as? NSNumber)?.intValue) ?? "other"
                completed.append([
                    "id": id, "name": item["title"] as? String ?? "Activity",
                    "date": itemDate, "sport": sport, "duration_minutes": durationMinutes,
                    "description": ""
                ])
            } else if itemType == "fbtAdaptiveWorkout" {
                let uuid = item["workoutUuid"] as? String ?? ""
                if uuid.isEmpty || seen.contains(uuid) { continue }
                seen.insert(uuid)
                // Garmin-coach workouts are planned but not editable via our API.
                scheduled.append([
                    "workout_id": uuid, "date": itemDate, "editable": false,
                    "workout_data": [
                        "name": "[GC] \(item["title"] as? String ?? "Training Plan Workout")",
                        "sport": item["sportTypeKey"] as? String ?? "other",
                        "duration_minutes": NSNull(), "description": "", "steps": []
                    ]
                ])
            }
        }

        // Completed activities by date
        if let activities = try? await client.getActivitiesByDate(start: start, end: end) {
            for activity in activities {
                let id = activity["activityId"].map { "\($0)" } ?? ""
                if id.isEmpty || seen.contains(id) { continue }
                seen.insert(id)
                let st = activity["startTimeLocal"] as? String ?? ""
                completed.append([
                    "id": id, "name": activity["activityName"] as? String ?? "Unnamed Activity",
                    "date": st.count >= 10 ? String(st.prefix(10)) : "",
                    "sport": (activity["activityType"] as? [String: Any])?["typeKey"] as? String ?? "Unknown",
                    "duration_minutes": Coerce.double(activity["duration"]).map { Int(($0 / 60).rounded()) } ?? NSNull(),
                    "description": activity["description"] as? String ?? ""
                ])
            }
        }

        scheduled.sort { ($0["date"] as? String ?? "") < ($1["date"] as? String ?? "") }
        completed.sort { ($0["date"] as? String ?? "") < ($1["date"] as? String ?? "") }
        let data: [String: Any] = [
            "period": ["start": start, "end": end],
            "scheduled": scheduled, "completed": completed,
            "scheduled_count": scheduled.count, "completed_count": completed.count
        ]
        return resultString(success: true, data: data, message: "Found \(scheduled.count) scheduled and \(completed.count) completed between \(start) and \(end)")
    }

    /// Every `(year, month)` pair the inclusive `[start, end]` window touches, where
    /// both bounds are `YYYY-MM-DD`. Garmin's calendar endpoint is per-month, so a
    /// window crossing a boundary needs one call per month.
    private static func monthsSpanned(start: String, end: String) -> [(year: Int, month: Int)] {
        func monthIndex(_ ymd: String) -> Int? {
            let parts = ymd.split(separator: "-")
            guard parts.count >= 2, let y = Int(parts[0]), let m = Int(parts[1]) else { return nil }
            return y * 12 + (m - 1)
        }
        guard let lo = monthIndex(start), let hi = monthIndex(end), lo <= hi else { return [] }
        return (lo...hi).map { (year: $0 / 12, month: $0 % 12 + 1) }
    }

    /// Flatten a Garmin workout-details payload into the compact step shape
    /// `PlannedTSS` consumes (see `CoachTools` add_workout). Repeat groups are
    /// expanded by their iteration count and pace targets (stored by Garmin as
    /// m/s) are converted to seconds (sec/km, or sec/100 m for swims) so they
    /// match the coach-supplied convention.
    private func compactSteps(fromDetails details: [String: Any], sport: String) -> [[String: Any]] {
        let segments = details["workoutSegments"] as? [[String: Any]] ?? []
        let isSwim = WorkoutNormalizer.swimSportKeys.contains(sport)
        // Repeat groups are PRESERVED (emitted as a `repeat` block with
        // `repeat_count`/`repeat_steps`) rather than flattened, so the real
        // "3×12 min" structure survives for the UI. `PlannedTSS` expands them and
        // `GarminWorkoutBuilder` rebuilds them, so this stays symmetric.
        func leaf(_ step: [String: Any]) -> [String: Any] {
            var compact: [String: Any] = [
                "type": (step["stepType"] as? [String: Any])?["stepTypeKey"] as? String ?? "interval"
            ]
            let endKey = (step["endCondition"] as? [String: Any])?["conditionTypeKey"] as? String ?? "time"
            let endValue = Coerce.double(step["endConditionValue"]) ?? 0
            if endKey.contains("distance") {
                compact["distance_meters"] = endValue
            } else {
                compact["duration_seconds"] = endValue
            }
            let targetKey = (step["targetType"] as? [String: Any])?["workoutTargetTypeKey"] as? String ?? "no.target"
            if let low = Coerce.double(step["targetValueOne"]), let high = Coerce.double(step["targetValueTwo"]) {
                switch targetKey {
                case "power.zone":
                    compact["target_type"] = "power"
                    compact["target_low"] = low; compact["target_high"] = high
                case "heart.rate.zone":
                    compact["target_type"] = "heart_rate"
                    compact["target_low"] = low; compact["target_high"] = high
                case "pace.zone" where low > 0 && high > 0:
                    let factor = isSwim ? 100.0 : 1000.0
                    compact["target_type"] = "pace"
                    compact["target_low"] = factor / high   // faster speed ⇒ smaller seconds
                    compact["target_high"] = factor / low
                case "speed.zone" where low > 0 && high > 0:
                    compact["target_type"] = "speed"   // Garmin stores m/s → km/h
                    compact["target_low"] = round1(low * 3.6)
                    compact["target_high"] = round1(high * 3.6)
                case "cadence.zone":
                    compact["target_type"] = "cadence"
                    compact["target_low"] = low; compact["target_high"] = high
                default:
                    break
                }
            }
            return compact
        }
        func walk(_ stepList: [[String: Any]]) -> [[String: Any]] {
            var out: [[String: Any]] = []
            for step in stepList {
                if (step["type"] as? String) == "RepeatGroupDTO" {
                    let iterations = max(1, Coerce.double(step["numberOfIterations"]).map { Int($0) } ?? 1)
                    let children = walk(step["workoutSteps"] as? [[String: Any]] ?? [])
                    out.append(["type": "repeat", "repeat_count": iterations, "repeat_steps": children])
                } else {
                    out.append(leaf(step))
                }
            }
            return out
        }
        var out: [[String: Any]] = []
        for segment in segments { out.append(contentsOf: walk(segment["workoutSteps"] as? [[String: Any]] ?? [])) }
        return out
    }

    // MARK: - delete_workout

    func deleteWorkout(workoutId: String) async -> String {
        do {
            try await client.deleteWorkout(workoutId: workoutId)
            return resultString(success: true, data: ["deleted_workout_id": workoutId], message: "Successfully deleted workout \(workoutId)")
        } catch {
            return resultString(success: false, data: nil, message: "Failed to delete workout \(workoutId): \(authMessage(error))")
        }
    }

    // MARK: - add_workouts (single add)

    func addWorkout(workoutData: [String: Any], date: String) async -> String {
        do {
            let targetDate = GarminTransform.formatDate(date)
            let sport = Coerce.token(workoutData["sport"] as? String, default: "other")
            let sportType = GarminMappings.workoutSportTypes[sport] ?? GarminMappings.workoutSportTypes["other"]!
            let json = GarminWorkoutBuilder.buildWorkoutJSON(workoutData, sportType: sportType, sport: sport)
            let created = try await client.uploadWorkout(json)
            let workoutId = created?["workoutId"].map { "\($0)" }
            if let workoutId { try await client.scheduleWorkout(workoutId: workoutId, date: targetDate) }
            let data: [String: Any] = [
                "workout_id": workoutId ?? NSNull(), "name": workoutData["name"] ?? NSNull(),
                "date": targetDate, "sport": sport
            ]
            return resultString(success: true, data: data, message: "Created and scheduled '\(workoutData["name"] as? String ?? "Workout")' for \(targetDate)")
        } catch {
            return resultString(success: false, data: nil, message: "Failed to add workout: \(authMessage(error))")
        }
    }

    // MARK: - move_workout

    func moveWorkout(workoutId: String, toDate: String, fromDate: String?) async -> String {
        let target = GarminTransform.formatDate(toDate)
        do {
            // Find the workout's current scheduled occurrence: its date and the
            // calendar item's `id` (the schedule-occurrence id, distinct from the
            // workout template id) so we can delete the OLD occurrence. Garmin's
            // POST /schedule is additive (it adds an occurrence, it does not move
            // one), so a real move must unschedule the source occurrence — otherwise
            // the workout lingers on both days and the next sync snaps it back.
            var sourceDate: String?
            var scheduleId: String?
            var workoutName = "Workout \(workoutId)"

            // Scan just the source month when given (fast path); otherwise the next
            // few months from today, which covers typical "this/next week" moves.
            let months: [(Int, Int)]
            if let fromDate {
                let p = GarminTransform.formatDate(fromDate).split(separator: "-")
                months = (p.count >= 2 ? [(Int(p[0]) ?? 0, Int(p[1]) ?? 0)] : []).filter { $0.0 > 0 && $0.1 > 0 }
            } else {
                let cal = Calendar.current
                months = (0...2).compactMap { offset in
                    guard let d = cal.date(byAdding: .month, value: offset, to: Date()) else { return nil }
                    let c = cal.dateComponents([.year, .month], from: d)
                    guard let y = c.year, let m = c.month else { return nil }
                    return (y, m)
                }
            }

            outer: for (year, month) in months {
                guard let calData = try? await client.connectapi("/calendar-service/year/\(year)/month/\(month - 1)") as? [String: Any],
                      let items = calData["calendarItems"] as? [[String: Any]] else { continue }
                for item in items where (item["itemType"] as? String) == "workout"
                    && item["workoutId"] != nil && "\(item["workoutId"]!)" == workoutId {
                    sourceDate = item["date"] as? String
                    scheduleId = item["id"].map { "\($0)" }
                    workoutName = item["title"] as? String ?? workoutName
                    break outer
                }
            }

            // Schedule on the new date first; only then drop the old occurrence,
            // so a failure to schedule never leaves the workout unscheduled.
            try await client.scheduleWorkout(workoutId: workoutId, date: target)
            if let scheduleId {
                try? await client.unscheduleWorkout(scheduleId: scheduleId)
            }
            let data: [String: Any] = ["workout_id": workoutId, "workout_name": workoutName, "from_date": sourceDate ?? NSNull(), "to_date": target]
            return resultString(success: true, data: data, message: "Moved '\(workoutName)' to \(target)")
        } catch {
            return resultString(success: false, data: nil, message: "Failed to move workout: \(authMessage(error))")
        }
    }

    // MARK: - modify_workout

    /// Edit an existing workout's content in place via PUT. The schedule
    /// occurrence (id + date) is untouched — date changes belong to moveWorkout.
    func modifyWorkout(workoutId: String, workoutData: [String: Any]) async -> String {
        do {
            guard let existing = try await client.getWorkoutDetails(workoutId: workoutId) else {
                return resultString(success: false, data: nil, message: "Workout \(workoutId) not found")
            }
            let existingSportKey = (existing["sportType"] as? [String: Any])?["sportTypeKey"] as? String
            let sport = Coerce.token(workoutData["sport"] as? String ?? existingSportKey, default: "other")
            let sportType = GarminMappings.workoutSportTypes[sport] ?? GarminMappings.workoutSportTypes["other"]!

            var json: [String: Any]
            if workoutData["steps"] != nil {
                // Structural edit: rebuild the payload from the new definition.
                json = GarminWorkoutBuilder.buildWorkoutJSON(workoutData, sportType: sportType, sport: sport)
            } else {
                // Lightweight edit: keep the existing payload and override only the
                // provided top-level fields, preserving the existing step ids.
                json = existing
                if let name = workoutData["name"] as? String { json["workoutName"] = name }
                if let desc = workoutData["description"] as? String { json["description"] = desc }
            }
            // Garmin's PUT requires the identity fields in the body.
            json["workoutId"] = Int(workoutId) ?? existing["workoutId"] ?? workoutId
            if let ownerId = existing["ownerId"] { json["ownerId"] = ownerId }

            _ = try await client.updateWorkout(workoutId: workoutId, json: json)

            let name = workoutData["name"] as? String ?? existing["workoutName"] as? String ?? "Workout"
            let data: [String: Any] = ["workout_id": workoutId, "name": name, "sport": sport]
            return resultString(success: true, data: data, message: "Updated '\(name)'")
        } catch {
            return resultString(success: false, data: nil, message: "Failed to modify workout \(workoutId): \(authMessage(error))")
        }
    }

    // MARK: - sync_user_settings

    /// Returns (renderedString, settings). `settings` is nil on failure.
    ///
    /// Scoped to what the range endpoints (see `fetchMetricHistory`) do NOT
    /// provide: HR zones + max HR, and power zones (bucketed from the current
    /// cycling FTP). The dated FTP/VO2max/threshold/CSS/weight time series are
    /// owned by `fetchMetricHistory`; `cycling_ftp` is read here only to derive
    /// the power-zone bands and is not emitted as a metric.
    func syncUserSettings() async -> (text: String, settings: [String: Any]?) {
        var settings: [String: Any] = [:]

        if let hrZones = try? await client.connectapi("/biometric-service/heartRateZones") as? [[String: Any]], !hrZones.isEmpty {
            let defaultZones = hrZones.first { ($0["sport"] as? String) == "DEFAULT" } ?? hrZones[0]
            if let maxHR = (defaultZones["maxHeartRateUsed"] as? NSNumber)?.intValue { settings["max_hr"] = maxHR }
            func z(_ key: String) -> Int { (defaultZones[key] as? NSNumber)?.intValue ?? 0 }
            settings["hr_zones"] = zoneBands([
                0, z("zone1Floor"), z("zone2Floor"), z("zone3Floor"), z("zone4Floor"), z("maxHeartRateUsed")
            ])
        }

        // Power zones are bucketed from the current cycling FTP. The FTP series
        // itself comes from fetchMetricHistory, so we read the latest value only.
        if let ftp = try? await client.getCyclingFtp(),
           let dict = ftp as? [String: Any],
           let value = (dict["functionalThresholdPower"] as? NSNumber)?.intValue, value > 0 {
            let f = Double(value)
            let bounds = [0, 0.55, 0.75, 0.90, 1.05, 1.20].map { Int((f * $0).rounded()) }
            settings["power_zones"] = zoneBands(bounds)
        }

        if settings.isEmpty {
            return (resultString(success: false, data: nil, message: "Could not retrieve HR/power zones from Garmin"), nil)
        }
        let message = "Synced training zones from Garmin: "
            + "maxHR=\(settings["max_hr"].map { "\($0)" } ?? "N/A") bpm, "
            + "HR zones \(settings["hr_zones"] != nil ? "✓" : "—"), "
            + "power zones \(settings["power_zones"] != nil ? "✓" : "—")"
        return (resultString(success: true, data: settings, message: message), settings)
    }
}
