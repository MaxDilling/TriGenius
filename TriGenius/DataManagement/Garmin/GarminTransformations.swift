import Foundation

// MARK: - Garmin Data Transformations
//
// Ported from TriGenius_python/garmin/transformations.py. Pure functions for
// shaping raw Garmin API responses into coach-friendly structures.

nonisolated enum GarminTransform {

    /// Convert a supported date input into YYYY-MM-DD format.
    static func formatDate(_ input: String) -> String {
        let formats = ["yyyy-MM-dd", "dd/MM/yyyy", "MM/dd/yyyy", "dd-MM-yyyy"]
        for fmt in formats {
            let parser = DateFormatter()
            parser.locale = Locale(identifier: "en_US_POSIX")
            parser.dateFormat = fmt
            if let date = parser.date(from: input) {
                return DateFormatter.ymd.string(from: date)
            }
        }
        return input
    }

    static func date(from ymd: String) -> Date? {
        DateFormatter.ymd.date(from: ymd)
    }

    static func ymd(_ date: Date) -> String {
        DateFormatter.ymd.string(from: date)
    }

    /// Convert speed in m/s into pace (mm:ss) for the requested reference distance.
    static func speedToPace(_ speedMps: Double?, distanceM: Double = 1000) -> String? {
        guard let speedMps, speedMps > 0 else { return nil }
        let paceSeconds = distanceM / speedMps
        let minutes = Int(paceSeconds / 60)
        let seconds = Int(paceSeconds.truncatingRemainder(dividingBy: 60))
        return String(format: "%d:%02d", minutes, seconds)
    }

    /// Format seconds as mm:ss.
    static func formatSplitTime(_ seconds: Double?) -> String? {
        guard let seconds, seconds != 0 else { return nil }
        let minutes = Int(seconds / 60)
        let rem = Int(seconds.truncatingRemainder(dividingBy: 60))
        return String(format: "%d:%02d", minutes, rem)
    }

    /// Format seconds as mm:ss.d.
    static func formatSplitTimeSubsec(_ seconds: Double?) -> String? {
        guard let seconds, seconds != 0 else { return nil }
        let minutes = Int(seconds / 60)
        let rem = seconds.truncatingRemainder(dividingBy: 60)
        if minutes > 0 { return String(format: "%d:%04.1f", minutes, rem) }
        return String(format: "0:%04.1f", rem)
    }

    /// Analyze a simple trend from newest-first values.
    static func analyzeTrend(_ values: [Double]) -> String {
        guard values.count >= 3 else { return "Insufficient data" }
        let recent = values.prefix(3).reduce(0, +) / 3
        let older = values.suffix(3).reduce(0, +) / 3
        let diffPct = older > 0 ? ((recent - older) / older) * 100 : 0
        if diffPct > 5 { return "Improving" }
        if diffPct < -5 { return "Declining" }
        return "Stable"
    }

    static func countBySport(_ activities: [[String: Any]]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for a in activities {
            let sport = a["sport"] as? String ?? "other"
            counts[sport, default: 0] += 1
        }
        return counts
    }

    static func calculateActivitySummary(_ activities: [[String: Any]]) -> [String: Any] {
        guard !activities.isEmpty else { return [:] }
        let totalDuration = activities.reduce(0.0) { $0 + (($1["duration_minutes"] as? Double) ?? 0) }
        let totalDistance = activities.reduce(0.0) { $0 + (($1["distance_km"] as? Double) ?? 0) }
        let avgHR = activities.compactMap { $0["avg_hr"] as? Int }
        var out: [String: Any] = [
            "total_activities": activities.count,
            "total_duration_minutes": (totalDuration * 10).rounded() / 10,
            "total_distance_km": (totalDistance * 100).rounded() / 100,
            "sports_breakdown": countBySport(activities)
        ]
        out["avg_heart_rate"] = avgHR.isEmpty ? NSNull() : Int((Double(avgHR.reduce(0, +)) / Double(avgHR.count)).rounded())
        return out
    }

    /// Contiguous sample segments for a named time-series metric (e.g. `directPower`,
    /// `directSpeed`) from Garmin activity details, split on recording gaps (>1 s).
    static func metricSegments(_ details: [String: Any], key: String) -> [[Double]] {
        guard let descriptors = details["metricDescriptors"] as? [[String: Any]],
              let rows = details["activityDetailMetrics"] as? [[String: Any]],
              !descriptors.isEmpty, !rows.isEmpty else { return [] }

        var descriptorIndexes: [String: Int] = [:]
        for d in descriptors {
            if let k = d["key"] as? String, let idx = d["metricsIndex"] as? Int {
                descriptorIndexes[k] = idx
            }
        }
        guard let valueIdx = descriptorIndexes[key] else { return [] }
        let timestampIdx = descriptorIndexes["directTimestamp"]

        var segments: [[Double]] = []
        var current: [Double] = []
        var previousTimestamp: Double?

        for row in rows {
            guard let metrics = row["metrics"] as? [Any], valueIdx < metrics.count else { continue }
            let value = (metrics[valueIdx] as? NSNumber)?.doubleValue
            let timestampValue: Double? = {
                if let ti = timestampIdx, ti < metrics.count { return (metrics[ti] as? NSNumber)?.doubleValue }
                return nil
            }()

            guard let v = value else {
                if !current.isEmpty { segments.append(current); current = [] }
                previousTimestamp = nil
                continue
            }

            if let ts = timestampValue, let prev = previousTimestamp {
                let delta = Int(((ts - prev) / 1000).rounded())
                if delta > 1 {
                    if !current.isEmpty { segments.append(current) }
                    current = []
                }
            }
            current.append(v)
            previousTimestamp = timestampValue
        }
        if !current.isEmpty { segments.append(current) }
        return segments
    }

    /// (offset-from-first-sample seconds, value) samples for a named detail metric —
    /// the stream shape `WorkoutStreams` bins. Offsets come from `directTimestamp`
    /// (ms), falling back to the row index (the detail grid is ~1 Hz); null-value
    /// rows are skipped, so recording gaps stay empty bins.
    static func metricSamples(_ details: [String: Any], key: String) -> [(offset: Double, value: Double)] {
        guard let descriptors = details["metricDescriptors"] as? [[String: Any]],
              let rows = details["activityDetailMetrics"] as? [[String: Any]],
              !descriptors.isEmpty, !rows.isEmpty else { return [] }
        var indexes: [String: Int] = [:]
        for d in descriptors {
            if let k = d["key"] as? String, let idx = d["metricsIndex"] as? Int { indexes[k] = idx }
        }
        guard let valueIdx = indexes[key] else { return [] }
        let timestampIdx = indexes["directTimestamp"]

        var firstTimestamp: Double?
        var samples: [(offset: Double, value: Double)] = []
        for (rowIndex, row) in rows.enumerated() {
            guard let metrics = row["metrics"] as? [Any], valueIdx < metrics.count,
                  let value = (metrics[valueIdx] as? NSNumber)?.doubleValue else { continue }
            var offset = Double(rowIndex)
            if let ti = timestampIdx, ti < metrics.count,
               let ts = (metrics[ti] as? NSNumber)?.doubleValue {
                if firstTimestamp == nil { firstTimestamp = ts }
                offset = (ts - firstTimestamp!) / 1000
            }
            samples.append((offset, value))
        }
        return samples
    }

    /// 1 Hz HR samples from `heartRateDTOs` — where Garmin carries the HR stream
    /// for pool swims (their detail grid is per-length, not per-second).
    static func heartRateSamples(_ details: [String: Any]) -> [(offset: Double, value: Double)] {
        guard let dtos = details["heartRateDTOs"] as? [[String: Any]] else { return [] }
        return dtos.compactMap { dto in
            guard let t = (dto["duration"] as? NSNumber)?.doubleValue,
                  let bpm = (dto["bpm"] as? NSNumber)?.doubleValue, bpm > 0 else { return nil }
            return (t, bpm)
        }
    }

    /// Normalized graded speed (m/s) — true NGP, the pace analogue of normalized power.
    /// Shapes the 1 Hz `directSpeed` stream into (speed, grade, 1 s) samples, then
    /// defers the grade adjustment + math to the shared `GradeAdjustedPace` /
    /// `NormalizedStream`. Grade-less runs (no `directGrade`/`directElevation`) reduce
    /// to plain normalized speed.
    static func normalizedSpeedMps(_ details: [String: Any]) -> Double? {
        let samples = gradedSpeedSamples(details)
        guard !samples.isEmpty else { return nil }
        return NormalizedStream.normalized(GradeAdjustedPace.adjusted(samples))
    }

    /// Walk the activity-detail rows once into index-aligned `directSpeed` samples (m/s,
    /// 1 s) and their gradient: `directGrade` (percent) per row when present — Garmin
    /// pre-smooths it — else the de-noised `GradeAdjustedPace.smoothedGrades` over the
    /// `directElevation`/`sumDistance` series (last values carried across the odd missing
    /// row), else flat.
    private static func gradedSpeedSamples(_ details: [String: Any]) -> [(speed: Double, grade: Double, seconds: Double)] {
        guard let descriptors = details["metricDescriptors"] as? [[String: Any]],
              let rows = details["activityDetailMetrics"] as? [[String: Any]],
              !descriptors.isEmpty, !rows.isEmpty else { return [] }

        var indexes: [String: Int] = [:]
        for d in descriptors {
            if let k = d["key"] as? String, let idx = d["metricsIndex"] as? Int { indexes[k] = idx }
        }
        guard let speedIdx = indexes["directSpeed"] else { return [] }
        let gradeIdx = indexes["directGrade"]
        let elevIdx = indexes["directElevation"]
        let distIdx = indexes["sumDistance"]
        let haveElevation = elevIdx != nil && distIdx != nil

        func value(_ metrics: [Any], _ idx: Int?) -> Double? {
            guard let idx, idx < metrics.count else { return nil }
            return (metrics[idx] as? NSNumber)?.doubleValue
        }

        var speeds: [Double] = []
        var directGrades: [Double] = []
        var elevations: [Double] = []
        var distances: [Double] = []
        var lastElevation = 0.0, lastDistance = 0.0

        for row in rows {
            guard let metrics = row["metrics"] as? [Any],
                  let speed = value(metrics, speedIdx), speed >= 0 else { continue }
            speeds.append(speed)
            if let g = value(metrics, gradeIdx) { directGrades.append(g / 100.0) }
            if haveElevation {
                lastElevation = value(metrics, elevIdx) ?? lastElevation
                lastDistance = value(metrics, distIdx) ?? lastDistance
                elevations.append(lastElevation); distances.append(lastDistance)
            }
        }
        guard !speeds.isEmpty else { return [] }

        let grades: [Double]
        if directGrades.count == speeds.count {
            grades = directGrades
        } else if haveElevation {
            grades = GradeAdjustedPace.smoothedGrades(distance: distances, altitude: elevations)
        } else {
            grades = Array(repeating: 0, count: speeds.count)
        }
        return zip(speeds, grades).map { (speed: $0, grade: $1, seconds: 1.0) }
    }

    /// Flatten a swim's lap DTOs into the ACTIVE pool lengths (idle/rest lengths
    /// carry no distance and are skipped) for `SwimLengthCleaner`.
    static func activeSwimLengths(_ lapDTOs: [[String: Any]]) -> [SwimLength] {
        var out: [SwimLength] = []
        for lap in lapDTOs {
            guard let lengths = lap["lengthDTOs"] as? [[String: Any]] else { continue }
            for l in lengths {
                let dur = Coerce.double(l["duration"]) ?? 0
                let dist = Coerce.double(l["distance"]) ?? 0
                guard dur > 0, dist > 0 else { continue }
                out.append(SwimLength(durationSeconds: dur,
                                      strokes: Int(Coerce.double(l["totalNumberOfStrokes"]) ?? 0),
                                      distanceMeters: dist))
            }
        }
        return out
    }

    // MARK: - Metric-history range parsers
    //
    // Pure shaping of the Garmin range/daily/weekly wellness + performance
    // endpoints into `(day, value)` samples. `GarminService.fetchMetricHistory`
    // maps each list onto a `metricKey`/`unit`. A `calendarDate`/`summaryDate`/
    // `updatedDate` (`YYYY-MM-DD`) or an ISO `measurementTimestampLocal`
    // (`…THH:mm:ss`) anchors each sample to its local day.

    typealias DatedValue = (date: Date, value: Double)

    /// Parse a `YYYY-MM-DD` or ISO `YYYY-MM-DDT…` string to a start-of-day date.
    private static func day(_ raw: Any?) -> Date? {
        guard let s = raw as? String, s.count >= 10 else { return nil }
        return date(from: String(s.prefix(10)))
    }

    /// HRV: `hrvSummaries[].lastNightAvg` @ `calendarDate` (ms).
    static func parseHrvOvernight(_ obj: [String: Any]?) -> [DatedValue] {
        guard let rows = obj?["hrvSummaries"] as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let d = day(row["calendarDate"]), let v = Coerce.double(row["lastNightAvg"]), v > 0 else { return nil }
            return (d, v)
        }
    }

    /// Sleep daily stats: `individualStats[].values` → per-metric `(day, value)`
    /// lists keyed by the stored metric key. Carries the full overnight picture:
    /// score, total duration, the four sleep-stage durations (deep / light / REM
    /// / awake), and the night's resting HR — the sleep endpoint is the reliable
    /// per-day source for `resting_hr` (the standalone heart-rate range endpoint
    /// returns a different envelope and yielded no history).
    static func parseSleepStats(_ obj: [String: Any]?) -> [String: [DatedValue]] {
        guard let rows = obj?["individualStats"] as? [[String: Any]] else { return [:] }
        var out: [String: [DatedValue]] = [:]
        for row in rows {
            guard let d = day(row["calendarDate"]), let values = row["values"] as? [String: Any] else { continue }
            func add(_ key: String, _ raw: Any?, scale: Double = 1) {
                guard let v = Coerce.double(raw), v > 0 else { return }
                out[key, default: []].append((d, v * scale))
            }
            add("sleep_score", values["sleepScore"])
            add("sleep_duration_h", values["totalSleepTimeInSeconds"], scale: 1.0 / 3600)
            add("sleep_deep_h", values["deepTime"], scale: 1.0 / 3600)
            add("sleep_light_h", values["lightTime"], scale: 1.0 / 3600)
            add("sleep_rem_h", values["remTime"], scale: 1.0 / 3600)
            add("sleep_awake_h", values["awakeTime"], scale: 1.0 / 3600)
            add("resting_hr", values["restingHeartRate"])
        }
        return out
    }

    /// Weight range: `dailyWeightSummaries[].latestWeight.weight` (grams) → kg.
    static func parseWeightKg(_ obj: [String: Any]?) -> [DatedValue] {
        guard let rows = obj?["dailyWeightSummaries"] as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let d = day(row["summaryDate"]),
                  let g = Coerce.double((row["latestWeight"] as? [String: Any])?["weight"]), g > 0 else { return nil }
            return (d, (g / 1000 * 10).rounded() / 10)
        }
    }

    /// VO2max weekly: each entry's `generic`/`cycling` sub-object carries its own
    /// `calendarDate` + `vo2MaxPreciseValue`. `subKey` selects run (`generic`) vs cycle.
    static func parseVo2Max(_ arr: [[String: Any]]?, subKey: String) -> [DatedValue] {
        guard let arr else { return [] }
        return arr.compactMap { entry in
            guard let sub = entry[subKey] as? [String: Any],
                  let d = day(sub["calendarDate"]),
                  let v = Coerce.double(sub["vo2MaxPreciseValue"]), v > 0 else { return nil }
            return (d, v)
        }
    }

    /// FTP range: `[]{series, value, updatedDate}` filtered to one `series` (watts).
    static func parseFtp(_ arr: [[String: Any]]?, series: String) -> [DatedValue] {
        guard let arr else { return [] }
        return arr.compactMap { row in
            guard (row["series"] as? String) == series,
                  let d = day(row["updatedDate"]), let v = Coerce.double(row["value"]), v > 0 else { return nil }
            return (d, v)
        }
    }

    /// CSS range: `criticalSwimSpeedDTOList[].criticalSwimSpeed` (mm/s) → m/s @
    /// `measurementTimestampLocal`.
    static func parseCssSpeed(_ obj: [String: Any]?) -> [DatedValue] {
        guard let rows = obj?["criticalSwimSpeedDTOList"] as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let d = day(row["measurementTimestampLocal"]),
                  let mm = Coerce.double(row["criticalSwimSpeed"]), mm > 0 else { return nil }
            return (d, mm / 1000)
        }
    }

    /// Lactate-threshold HR range: `[].value` @ `updatedDate` (bpm).
    static func parseThresholdHR(_ arr: [[String: Any]]?) -> [DatedValue] {
        guard let arr else { return [] }
        return arr.compactMap { row in
            guard let d = day(row["updatedDate"]), let v = Coerce.double(row["value"]), v > 0 else { return nil }
            return (d, v)
        }
    }

    /// Lactate-threshold speed range: `value` is in 0.1 m/s units (×10 → m/s),
    /// @ `updatedDate`. See `GarminClient` notes on this endpoint's scaling.
    static func parseThresholdSpeed(_ arr: [[String: Any]]?) -> [DatedValue] {
        guard let arr else { return [] }
        return arr.compactMap { row in
            guard let d = day(row["updatedDate"]), let v = Coerce.double(row["value"]), v > 0 else { return nil }
            return (d, v * 10)
        }
    }

    /// Build normalized swim interval data from Garmin lap DTOs.
    static func buildSwimIntervals(_ lapDTOs: [[String: Any]], poolLengthM: Double?) -> [[String: Any]] {
        var intervals: [[String: Any]] = []
        var cumulativeTime = 0.0
        var cumulativeDistance = 0.0
        var activeIntervalNum = 0

        for lap in lapDTOs {
            let duration = Coerce.double(lap["duration"]) ?? 0
            var distance = Coerce.double(lap["distance"]) ?? 0
            let numActiveLengths = Int(Coerce.double(lap["numberOfActiveLengths"]) ?? 0)
            let isRest = distance == 0 && numActiveLengths == 0

            cumulativeTime += duration

            let avgHR = Coerce.double(lap["averageHR"]).map { Int($0.rounded()) }
            let maxHR = Coerce.double(lap["maxHR"]).map { Int($0.rounded()) }
            let totalStrokes = Int(Coerce.double(lap["totalNumberOfStrokes"]) ?? 0)

            if isRest {
                var rest: [String: Any] = [:]
                rest["interval"] = "Rest"
                rest["is_rest"] = true
                rest["stroke"] = ""
                rest["stroke_id"] = NSNull()
                rest["lengths"] = 0
                rest["distance_m"] = 0
                rest["time_sec"] = duration != 0 ? (duration * 10).rounded() / 10 : 0
                rest["time_formatted"] = formatSplitTimeSubsec(duration) ?? NSNull()
                rest["cumulative_time_sec"] = (cumulativeTime * 10).rounded() / 10
                rest["cumulative_time_formatted"] = formatSplitTime(cumulativeTime) ?? NSNull()
                rest["cumulative_distance_m"] = (cumulativeDistance * 10).rounded() / 10
                rest["avg_pace_per_100m"] = NSNull()
                rest["swolf"] = NSNull()
                rest["strokes_per_length"] = NSNull()
                rest["avg_hr"] = avgHR ?? NSNull()
                rest["max_hr"] = maxHR ?? NSNull()
                rest["total_strokes"] = totalStrokes
                intervals.append(rest)
                continue
            }

            activeIntervalNum += 1
            cumulativeDistance += distance

            let lengths = lap["lengthDTOs"] as? [[String: Any]] ?? []
            let activeLengths = lengths.filter { ($0["swimStroke"] as? String)?.isEmpty == false }
            let numLengths = activeLengths.isEmpty ? numActiveLengths : activeLengths.count

            if distance == 0, let pool = poolLengthM, numLengths > 0 {
                distance = Double(numLengths) * pool
            }

            var strokeName = "mixed"
            var strokeId: Int? = nil
            if !activeLengths.isEmpty {
                var strokeCounts: [String: Int] = [:]
                for l in activeLengths {
                    let stroke = (l["swimStroke"] as? String) ?? ""
                    strokeCounts[stroke, default: 0] += 1
                }
                if let primary = strokeCounts.max(by: { $0.value < $1.value })?.key {
                    strokeName = GarminMappings.swimStrokesByName[primary] ?? primary.lowercased()
                }
            } else {
                if let code = (lap["swimStroke"] as? NSNumber)?.intValue
                    ?? (lap["primaryStrokeType"] as? NSNumber)?.intValue
                    ?? (lap["strokeType"] as? NSNumber)?.intValue {
                    strokeName = GarminMappings.swimStrokesByCode[code] ?? "unknown"
                    strokeId = code
                } else if let name = (lap["swimStroke"] as? String) {
                    strokeName = GarminMappings.swimStrokesByName[name] ?? "unknown"
                } else {
                    strokeName = "unknown"
                }
            }

            var avgPace: String? = nil
            if duration > 0 && distance > 0 {
                avgPace = speedToPace(100 / ((duration / distance) * 100), distanceM: 100)
            }
            var bestPace: String? = nil
            if !activeLengths.isEmpty {
                let bestSpeed = activeLengths.compactMap { Coerce.double($0["averageSpeed"]) }.max() ?? 0
                if bestSpeed > 0 { bestPace = speedToPace(bestSpeed, distanceM: 100) }
            }

            let swolf = Coerce.double(lap["averageSWOLF"]) ?? Coerce.double(lap["avgSwolf"]) ?? Coerce.double(lap["swolf"])
            let strokesPerLength = Coerce.double(lap["averageStrokes"]) ?? Coerce.double(lap["avgStrokesPerLength"])

            var entry: [String: Any] = [:]
            entry["interval"] = activeIntervalNum
            entry["is_rest"] = false
            entry["stroke"] = strokeName
            entry["stroke_id"] = strokeId ?? NSNull()
            entry["lengths"] = numLengths
            entry["distance_m"] = distance != 0 ? (distance * 10).rounded() / 10 : 0
            entry["time_sec"] = duration != 0 ? (duration * 10).rounded() / 10 : 0
            entry["time_formatted"] = formatSplitTime(duration) ?? NSNull()
            entry["cumulative_time_sec"] = (cumulativeTime * 10).rounded() / 10
            entry["cumulative_time_formatted"] = formatSplitTime(cumulativeTime) ?? NSNull()
            entry["cumulative_distance_m"] = (cumulativeDistance * 10).rounded() / 10
            entry["avg_pace_per_100m"] = avgPace ?? NSNull()
            entry["best_pace_per_100m"] = bestPace ?? NSNull()
            entry["swolf"] = swolf.map { Int($0.rounded()) } ?? NSNull()
            entry["strokes_per_length"] = strokesPerLength.map { Int($0.rounded()) } ?? NSNull()
            entry["avg_hr"] = avgHR ?? NSNull()
            entry["max_hr"] = maxHR ?? NSNull()
            entry["total_strokes"] = totalStrokes
            entry["calories"] = Int(Coerce.double(lap["calories"]) ?? 0)
            intervals.append(entry)
        }
        return intervals
    }
}
