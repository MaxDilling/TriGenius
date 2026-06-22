import Foundation

// MARK: - Garmin Service
//
// High-level orchestration ported from TriGenius_python/garmin/service.py.
// Each public method returns a ToolResult-style JSON string for the coach,
// except `syncUserSettings` which also returns the parsed settings dict so the
// caller can persist them into CoachMemory (as the Python CLI does).

actor GarminService {

    static let shared = GarminService()
    private let client = GarminClient.shared
    private init() {}

    // MARK: - Result helpers

    private func num(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }
    /// JSON-safe value: the wrapped value, or NSNull when nil.
    private func orNull(_ v: Any?) -> Any { if let v { return v }; return NSNull() }
    private func round1(_ v: Double) -> Double { (v * 10).rounded() / 10 }
    private func round2(_ v: Double) -> Double { (v * 100).rounded() / 100 }

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

        func intOrNull(_ key: String) -> Any { num(activity[key]).map { Int($0.rounded()) } ?? NSNull() }

        var data: [String: Any] = [
            "id": activity["activityId"] ?? NSNull(),
            "name": activity["activityName"] as? String ?? "Activity",
            "date": startTime.count >= 10 ? String(startTime.prefix(10)) : "",
            "time": startTime.count > 11 ? String(startTime.dropFirst(11).prefix(5)) : "",
            "sport": activityType,
            "duration_minutes": round1((num(activity["duration"]) ?? 0) / 60),
            "distance_km": round2((num(activity["distance"]) ?? 0) / 1000),
            "calories": activity["calories"] ?? NSNull(),
            "location": activity["locationName"] ?? NSNull(),
            "avg_hr": intOrNull("averageHR"),
            "max_hr": intOrNull("maxHR"),
            "aerobic_te": num(activity["aerobicTrainingEffect"]).map { round1($0) } ?? NSNull(),
            "anaerobic_te": num(activity["anaerobicTrainingEffect"]).map { round1($0) } ?? NSNull(),
            "training_load": intOrNull("activityTrainingLoad"),
            "elevation_gain_m": intOrNull("elevationGain"),
            "elevation_loss_m": intOrNull("elevationLoss")
        ]
        if activity["hrTimeInZone_1"] != nil {
            data["hr_zones_seconds"] = [
                "z1": Int((num(activity["hrTimeInZone_1"]) ?? 0).rounded()),
                "z2": Int((num(activity["hrTimeInZone_2"]) ?? 0).rounded()),
                "z3": Int((num(activity["hrTimeInZone_3"]) ?? 0).rounded()),
                "z4": Int((num(activity["hrTimeInZone_4"]) ?? 0).rounded()),
                "z5": Int((num(activity["hrTimeInZone_5"]) ?? 0).rounded())
            ]
        }

        if ["running", "trail_running", "treadmill_running"].contains(activityType) {
            data["running"] = [
                "avg_pace_min_km": orNull(GarminTransform.speedToPace(num(activity["averageSpeed"]), distanceM: 1000)),
                "best_pace_min_km": orNull(GarminTransform.speedToPace(num(activity["maxSpeed"]), distanceM: 1000)),
                "avg_cadence_spm": orNull(num(activity["averageRunningCadenceInStepsPerMinute"]).map { Int($0.rounded()) }),
                "max_cadence_spm": orNull(num(activity["maxRunningCadenceInStepsPerMinute"]).map { Int($0.rounded()) }),
                "avg_power_w": orNull(num(activity["avgPower"]).map { Int($0.rounded()) }),
                "steps": orNull(activity["steps"])
            ]
        } else if ["cycling", "indoor_cycling", "virtual_ride"].contains(activityType) {
            let avgSpeed = num(activity["averageSpeed"]) ?? 0
            var cycling: [String: Any] = [
                "avg_speed_kmh": avgSpeed > 0 ? round1(avgSpeed * 3.6) : NSNull(),
                "max_speed_kmh": num(activity["maxSpeed"]).map { round1($0 * 3.6) } ?? NSNull(),
                "avg_power_w": num(activity["avgPower"]).map { Int($0.rounded()) } ?? NSNull(),
                "max_power_w": num(activity["maxPower"]).map { Int($0.rounded()) } ?? NSNull(),
                "normalized_power_w": num(activity["normPower"]).map { Int($0.rounded()) } ?? NSNull(),
                "avg_cadence_rpm": num(activity["avgBikingCadenceInRevPerMinute"]).map { Int($0.rounded()) } ?? NSNull()
            ]
            if activity["powerTimeInZone_1"] != nil {
                cycling["power_zones_seconds"] = [
                    "z1": Int((num(activity["powerTimeInZone_1"]) ?? 0).rounded()),
                    "z2": Int((num(activity["powerTimeInZone_2"]) ?? 0).rounded()),
                    "z3": Int((num(activity["powerTimeInZone_3"]) ?? 0).rounded()),
                    "z4": Int((num(activity["powerTimeInZone_4"]) ?? 0).rounded()),
                    "z5": Int((num(activity["powerTimeInZone_5"]) ?? 0).rounded())
                ]
            }
            data["cycling"] = cycling
        } else if activityType.lowercased().contains("swim") {
            let poolLengthM = num(activity["poolLength"]).map { $0 / 100 }
            let activityId = activity["activityId"].map { "\($0)" }
            var intervals: [[String: Any]]? = nil
            if let activityId {
                if let splits = try? await client.getActivitySplits(id: activityId),
                   let lapDTOs = splits["lapDTOs"] as? [[String: Any]], !lapDTOs.isEmpty {
                    let built = GarminTransform.buildSwimIntervals(lapDTOs, poolLengthM: poolLengthM)
                    intervals = built.isEmpty ? nil : built
                }
            }
            data["swimming"] = [
                "pool_length_m": poolLengthM ?? NSNull(),
                "avg_swolf": activity["averageSwolf"] ?? NSNull(),
                "avg_strokes_per_length": activity["avgStrokes"] ?? NSNull(),
                "total_lengths": activity["activeLengths"] ?? NSNull(),
                "avg_pace_per_100m": GarminTransform.speedToPace(num(activity["averageSpeed"]), distanceM: 100) ?? NSNull(),
                "intervals": intervals ?? NSNull()
            ]
        }
        return data
    }

    /// Build the local-DB ingest snapshot from a *formatted* coach record.
    /// Stores the full record as `detailsJSON` (so `get_activities` can serve it
    /// verbatim) plus the training load (`activityTrainingLoad`), the
    /// TSS-equivalent the PMC engine relies on. Returns nil without an id/date.
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
            tss: (rec["training_load"] as? NSNumber)?.doubleValue,
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
                let rec = await formatActivityRecord(activity)
                formatted.append(rec)
                if let dto = ingestDTO(from: rec) { toIngest.append(dto) }
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
    func backfillActivities(startDate: String, endDate: String) async -> Int? {
        do {
            let raw = try await client.getActivitiesByDate(start: startDate, end: endDate)
            var toIngest: [IngestedActivity] = []
            for activity in raw {
                let rec = await formatActivityRecord(activity)
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
        let sportKey = GarminMappings.normalizeToken(sport, default: "cycling")
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

    // MARK: - get_health_metrics

    func getHealthMetrics(days: Int = 7) async -> String {
        do {
            let end = Date()
            var dailyMetrics: [[String: Any]] = []
            for offset in 0..<days {
                let current = Calendar.current.date(byAdding: .day, value: -offset, to: end)!
                let dateStr = GarminTransform.ymd(current)
                var day: [String: Any] = ["date": dateStr]

                // HRV
                if let hrv = try? await client.getHrvData(date: dateStr),
                   let summary = hrv["hrvSummary"] as? [String: Any] {
                    day["hrv"] = [
                        "status": summary["status"] as? String ?? "Unknown",
                        "baseline": summary["baseline"] ?? NSNull(),
                        "last_night": summary["lastNightAvg"] ?? NSNull(),
                        "weekly_avg": summary["weeklyAvg"] ?? NSNull(),
                        "last_night_5min_high": summary["lastNight5MinHigh"] ?? NSNull()
                    ]
                } else { day["hrv"] = NSNull() }

                // Sleep
                if let sleep = try? await client.getSleepData(date: dateStr),
                   let dto = sleep["dailySleepDTO"] as? [String: Any] {
                    let scores = dto["sleepScores"] as? [String: Any] ?? [:]
                    let overall = (scores["overall"] as? [String: Any])?["value"]
                    let quality = (scores["totalDuration"] as? [String: Any])?["qualifierKey"] as? String ?? "Unknown"
                    day["sleep"] = [
                        "score": overall ?? NSNull(),
                        "duration_hours": round1((num(dto["sleepTimeSeconds"]) ?? 0) / 3600),
                        "quality": quality,
                        "deep_hours": round1((num(dto["deepSleepSeconds"]) ?? 0) / 3600),
                        "rem_hours": round1((num(dto["remSleepSeconds"]) ?? 0) / 3600),
                        "avg_hr": dto["avgHeartRate"] ?? NSNull()
                    ]
                } else { day["sleep"] = NSNull() }

                dailyMetrics.append(day)
            }

            func collect(_ path: (String, String)) -> [Double] {
                dailyMetrics.compactMap { entry in
                    guard let sub = entry[path.0] as? [String: Any] else { return nil }
                    return num(sub[path.1])
                }
            }
            let hrvValues = collect(("hrv", "last_night"))
            let sleepScores = collect(("sleep", "score"))
            let sleepDurations = collect(("sleep", "duration_hours"))

            func avg(_ vals: [Double], _ places: Int) -> Any {
                guard !vals.isEmpty else { return NSNull() }
                let a = vals.reduce(0, +) / Double(vals.count)
                let f = pow(10.0, Double(places))
                return (a * f).rounded() / f
            }

            let metrics: [String: Any] = [
                "period": ["start": GarminTransform.ymd(Calendar.current.date(byAdding: .day, value: -days, to: end)!),
                           "end": GarminTransform.ymd(end), "days": days],
                "daily_metrics": dailyMetrics,
                "summary": [
                    "avg_hrv": avg(hrvValues, 1),
                    "avg_sleep_score": avg(sleepScores, 1),
                    "avg_sleep_hours": avg(sleepDurations, 1),
                    "trend": hrvValues.isEmpty ? "Unknown" : GarminTransform.analyzeTrend(hrvValues)
                ]
            ]
            return resultString(success: true, data: metrics, message: "Retrieved health metrics for the last \(days) days")
        }
    }

    // MARK: - get_calendar

    func getCalendar(startDate: String, endDate: String) async -> String {
        let start = GarminTransform.formatDate(startDate)
        let end = GarminTransform.formatDate(endDate)
        do {
            var workouts: [[String: Any]] = []
            var seen = Set<String>()

            // Calendar items (scheduled workouts, activities, garmin coach)
            let parts = start.split(separator: "-")
            if parts.count >= 2, let year = Int(parts[0]), let month = Int(parts[1]) {
                if let calData = try? await client.connectapi("/calendar-service/year/\(year)/month/\(month - 1)") as? [String: Any],
                   let items = calData["calendarItems"] as? [[String: Any]] {
                    for item in items {
                        let itemDate = item["date"] as? String ?? ""
                        guard !itemDate.isEmpty, itemDate >= start, itemDate <= end else { continue }
                        let itemType = item["itemType"] as? String
                        if itemType == "workout", let workoutId = item["workoutId"] {
                            let id = "\(workoutId)"
                            if seen.contains(id) { continue }
                            seen.insert(id)
                            var durationMinutes: Any = NSNull()
                            var steps: [[String: Any]] = []
                            let sportKey = item["sportTypeKey"] as? String ?? "other"
                            if let details = try? await client.getWorkoutDetails(workoutId: id) {
                                if let est = num(details["estimatedDurationInSecs"]) {
                                    durationMinutes = Int((est / 60).rounded())
                                }
                                steps = compactSteps(fromDetails: details, sport: sportKey)
                            }
                            workouts.append([
                                "id": id, "name": item["title"] as? String ?? "Scheduled Workout",
                                "date": itemDate, "sport": sportKey,
                                "duration_minutes": durationMinutes, "description": "",
                                "steps": steps,
                                "completed": false, "source": "scheduled"
                            ])
                        } else if itemType == "activity" {
                            let id = item["id"].map { "\($0)" } ?? ""
                            if id.isEmpty || seen.contains(id) { continue }
                            seen.insert(id)
                            let elapsed = num(item["elapsedDuration"])
                            let durMs = num(item["duration"])
                            let durationMinutes: Any = elapsed.map { Int(($0 / 60).rounded()) }
                                ?? durMs.map { Int(($0 / 60000).rounded()) } ?? NSNull()
                            let sport = item["sportTypeKey"] as? String ?? activityTypeToSport((item["activityTypeId"] as? NSNumber)?.intValue) ?? "other"
                            workouts.append([
                                "id": id, "name": item["title"] as? String ?? "Activity",
                                "date": itemDate, "sport": sport, "duration_minutes": durationMinutes,
                                "description": "", "completed": true, "source": "activity"
                            ])
                        } else if itemType == "fbtAdaptiveWorkout" {
                            let uuid = item["workoutUuid"] as? String ?? ""
                            if uuid.isEmpty || seen.contains(uuid) { continue }
                            seen.insert(uuid)
                            workouts.append([
                                "id": uuid, "name": "[GC] \(item["title"] as? String ?? "Training Plan Workout")",
                                "date": itemDate, "sport": item["sportTypeKey"] as? String ?? "other",
                                "duration_minutes": NSNull(), "description": "",
                                "completed": false, "source": "garmin_coach"
                            ])
                        }
                    }
                }
            }

            // Completed activities by date
            if let activities = try? await client.getActivitiesByDate(start: start, end: end) {
                for activity in activities {
                    let id = activity["activityId"].map { "\($0)" } ?? ""
                    if id.isEmpty || seen.contains(id) { continue }
                    seen.insert(id)
                    let st = activity["startTimeLocal"] as? String ?? ""
                    workouts.append([
                        "id": id, "name": activity["activityName"] as? String ?? "Unnamed Activity",
                        "date": st.count >= 10 ? String(st.prefix(10)) : "",
                        "sport": (activity["activityType"] as? [String: Any])?["typeKey"] as? String ?? "Unknown",
                        "duration_minutes": num(activity["duration"]).map { Int(($0 / 60).rounded()) } ?? NSNull(),
                        "description": activity["description"] as? String ?? "",
                        "completed": true, "source": "activity"
                    ])
                }
            }

            workouts.sort { ($0["date"] as? String ?? "") < ($1["date"] as? String ?? "") }
            let data: [String: Any] = ["period": ["start": start, "end": end], "workouts": workouts, "count": workouts.count]
            return resultString(success: true, data: data, message: "Found \(workouts.count) workout(s) between \(start) and \(end)")
        }
    }

    /// Flatten a Garmin workout-details payload into the compact step shape
    /// `PlannedTSS` consumes (see `CoachTools` add_workout). Repeat groups are
    /// expanded by their iteration count and pace targets (stored by Garmin as
    /// m/s) are converted to seconds (sec/km, or sec/100 m for swims) so they
    /// match the coach-supplied convention.
    private func compactSteps(fromDetails details: [String: Any], sport: String) -> [[String: Any]] {
        let segments = details["workoutSegments"] as? [[String: Any]] ?? []
        let isSwim = GarminWorkoutBuilder.swimSportKeys.contains(sport)
        var out: [[String: Any]] = []
        func walk(_ stepList: [[String: Any]]) {
            for step in stepList {
                if (step["type"] as? String) == "RepeatGroupDTO" {
                    let iterations = max(1, num(step["numberOfIterations"]).map { Int($0) } ?? 1)
                    let children = step["workoutSteps"] as? [[String: Any]] ?? []
                    for _ in 0 ..< iterations { walk(children) }
                    continue
                }
                var compact: [String: Any] = [
                    "type": (step["stepType"] as? [String: Any])?["stepTypeKey"] as? String ?? "interval"
                ]
                let endKey = (step["endCondition"] as? [String: Any])?["conditionTypeKey"] as? String ?? "time"
                let endValue = num(step["endConditionValue"]) ?? 0
                if endKey.contains("distance") {
                    compact["distance_meters"] = endValue
                } else {
                    compact["duration_seconds"] = endValue
                }
                let targetKey = (step["targetType"] as? [String: Any])?["workoutTargetTypeKey"] as? String ?? "no.target"
                if let low = num(step["targetValueOne"]), let high = num(step["targetValueTwo"]) {
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
                    default:
                        break
                    }
                }
                out.append(compact)
            }
        }
        for segment in segments { walk(segment["workoutSteps"] as? [[String: Any]] ?? []) }
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

    // MARK: - add_workout

    func addWorkout(workoutData: [String: Any], date: String) async -> String {
        do {
            let targetDate = GarminTransform.formatDate(date)
            let sport = GarminMappings.normalizeToken(workoutData["sport"] as? String, default: "other")
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

    func moveWorkout(fromDate: String, toDate: String, workoutId: String?) async -> String {
        let source = GarminTransform.formatDate(fromDate)
        let target = GarminTransform.formatDate(toDate)
        do {
            // Resolve the scheduled occurrence on the source date via the raw
            // calendar service. We need BOTH the workout template id (to schedule
            // it on the target date) and the calendar item's `id` — the schedule
            // occurrence id — so we can delete the OLD occurrence. Garmin's
            // POST /schedule is additive (it adds an occurrence, it does not move
            // one), so without deleting the source-date schedule the workout
            // lingers on both days and the next calendar sync snaps it back to the
            // earlier date.
            var resolvedId = workoutId
            var scheduleId: String?
            var workoutName = workoutId.map { "Workout \($0)" } ?? ""
            let parts = source.split(separator: "-")
            if parts.count >= 2, let year = Int(parts[0]), let month = Int(parts[1]),
               let calData = try? await client.connectapi("/calendar-service/year/\(year)/month/\(month - 1)") as? [String: Any],
               let items = calData["calendarItems"] as? [[String: Any]] {
                let candidates = items.filter {
                    ($0["date"] as? String) == source
                        && ($0["itemType"] as? String) == "workout"
                        && $0["workoutId"] != nil
                        && (workoutId == nil || "\($0["workoutId"]!)" == workoutId)
                }
                if let first = candidates.first, let wid = first["workoutId"] {
                    resolvedId = "\(wid)"
                    scheduleId = first["id"].map { "\($0)" }
                    workoutName = first["title"] as? String ?? workoutName
                }
            }
            guard let resolvedId else {
                return resultString(success: false, data: nil, message: "No movable workouts found on \(source)")
            }
            // Schedule on the new date first; only then drop the old occurrence,
            // so a failure to schedule never leaves the workout unscheduled.
            try await client.scheduleWorkout(workoutId: resolvedId, date: target)
            if let scheduleId {
                try? await client.unscheduleWorkout(scheduleId: scheduleId)
            }
            let data: [String: Any] = ["workout_id": resolvedId, "workout_name": workoutName, "from_date": source, "to_date": target]
            return resultString(success: true, data: data, message: "Moved '\(workoutName)' from \(source) to \(target)")
        } catch {
            return resultString(success: false, data: nil, message: "Failed to move workout: \(authMessage(error))")
        }
    }

    // MARK: - sync_user_settings

    /// Returns (renderedString, settings). `settings` is nil on failure.
    func syncUserSettings() async -> (text: String, settings: [String: Any]?) {
        do {
            var settings: [String: Any] = [:]

            if let ftp = try? await client.getCyclingFtp() {
                if let dict = ftp as? [String: Any], let value = (dict["functionalThresholdPower"] as? NSNumber)?.intValue {
                    settings["cycling_ftp"] = value
                }
            }

            if let lactate = try? await client.getLactateThreshold() {
                if let speedHR = lactate["speed_and_heart_rate"] as? [String: Any] {
                    if let hr = (speedHR["heartRate"] as? NSNumber)?.intValue {
                        settings["lactate_threshold_hr"] = hr
                    }
                    // Running threshold speed (m/s) → pace per km ("m:ss").
                    if let speed = (speedHR["speed"] as? NSNumber)?.doubleValue,
                       let pace = GarminTransform.speedToPace(speed, distanceM: 1000) {
                        settings["lactate_threshold_pace"] = pace
                    }
                }
                if let power = lactate["power"] as? [String: Any],
                   let runFtp = (power["functionalThresholdPower"] as? NSNumber)?.intValue {
                    settings["running_ftp"] = runFtp
                }
            }

            if let hrZones = try? await client.connectapi("/biometric-service/heartRateZones") as? [[String: Any]], !hrZones.isEmpty {
                let defaultZones = hrZones.first { ($0["sport"] as? String) == "DEFAULT" } ?? hrZones[0]
                if let maxHR = (defaultZones["maxHeartRateUsed"] as? NSNumber)?.intValue { settings["max_hr"] = maxHR }
                func z(_ key: String) -> Int { (defaultZones[key] as? NSNumber)?.intValue ?? 0 }
                settings["hr_zones"] = [
                    "z1": [0, z("zone1Floor")], "z2": [z("zone1Floor"), z("zone2Floor")],
                    "z3": [z("zone2Floor"), z("zone3Floor")], "z4": [z("zone3Floor"), z("zone4Floor")],
                    "z5": [z("zone4Floor"), z("maxHeartRateUsed")]
                ]
            }

            if let profile = try? await client.getUserProfile(), let userData = profile["userData"] as? [String: Any] {
                if let v = userData["vo2MaxRunning"] { settings["vo2max_running"] = v }
                if let v = userData["vo2MaxCycling"] { settings["vo2max_cycling"] = v }
                if let w = num(userData["weight"]) { settings["weight_kg"] = round1(w / 1000) }
                if let h = userData["height"] { settings["height_cm"] = h }
                if let g = userData["gender"] as? String { settings["gender"] = g.lowercased() }
                if let b = userData["birthDate"] { settings["birth_date"] = b }
            }

            if let ftp = settings["cycling_ftp"] as? Int {
                let f = Double(ftp)
                settings["power_zones"] = [
                    "z1": [0, Int((f * 0.55).rounded())], "z2": [Int((f * 0.55).rounded()), Int((f * 0.75).rounded())],
                    "z3": [Int((f * 0.75).rounded()), Int((f * 0.90).rounded())], "z4": [Int((f * 0.90).rounded()), Int((f * 1.05).rounded())],
                    "z5": [Int((f * 1.05).rounded()), Int((f * 1.20).rounded())]
                ]
            }

            let today = GarminTransform.ymd(Date())
            if let css = try? await client.connectapi("/biometric-service/criticalSwimSpeed/latest/\(today)") as? [String: Any],
               let cssMm = (css["criticalSwimSpeed"] as? NSNumber)?.doubleValue, cssMm > 0 {
                if let pace = GarminTransform.speedToPace(cssMm / 1000, distanceM: 100) { settings["css_pace_per_100m"] = pace }
            }

            if settings.isEmpty {
                return (resultString(success: false, data: nil, message: "Could not retrieve any user settings from Garmin"), nil)
            }
            let message = "Retrieved settings from Garmin: "
                + "FTP=\(settings["cycling_ftp"].map { "\($0)" } ?? "N/A")W, "
                + "LTHR=\(settings["lactate_threshold_hr"].map { "\($0)" } ?? "N/A") bpm, "
                + "LT pace=\(settings["lactate_threshold_pace"].map { "\($0)" } ?? "N/A")/km, "
                + "VO2max=\(settings["vo2max_running"].map { "\($0)" } ?? "N/A"), "
                + "CSS=\(settings["css_pace_per_100m"].map { "\($0)" } ?? "N/A")"
            return (resultString(success: true, data: settings, message: message), settings)
        }
    }
}
