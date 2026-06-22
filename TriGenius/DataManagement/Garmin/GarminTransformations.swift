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

    /// Format duration seconds into compact power-curve labels.
    static func formatDurationLabel(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        return "\(seconds / 3600)h"
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
        let te = activities.compactMap { $0["aerobic_te"] as? Double }
        var out: [String: Any] = [
            "total_activities": activities.count,
            "total_duration_minutes": (totalDuration * 10).rounded() / 10,
            "total_distance_km": (totalDistance * 100).rounded() / 100,
            "sports_breakdown": countBySport(activities)
        ]
        out["avg_heart_rate"] = avgHR.isEmpty ? NSNull() : Int((Double(avgHR.reduce(0, +)) / Double(avgHR.count)).rounded())
        out["avg_training_effect"] = te.isEmpty ? NSNull() : ((te.reduce(0, +) / Double(te.count)) * 10).rounded() / 10
        return out
    }

    /// Extract contiguous directPower sample segments from Garmin activity details.
    static func extractPowerSegments(_ details: [String: Any]) -> [[Double]] {
        guard let descriptors = details["metricDescriptors"] as? [[String: Any]],
              let rows = details["activityDetailMetrics"] as? [[String: Any]],
              !descriptors.isEmpty, !rows.isEmpty else { return [] }

        var descriptorIndexes: [String: Int] = [:]
        for d in descriptors {
            if let key = d["key"] as? String, let idx = d["metricsIndex"] as? Int {
                descriptorIndexes[key] = idx
            }
        }
        guard let powerIdx = descriptorIndexes["directPower"] else { return [] }
        let timestampIdx = descriptorIndexes["directTimestamp"]

        var segments: [[Double]] = []
        var current: [Double] = []
        var previousTimestamp: Double?

        for row in rows {
            guard let metrics = row["metrics"] as? [Any], powerIdx < metrics.count else { continue }
            let powerValue = (metrics[powerIdx] as? NSNumber)?.doubleValue
            let timestampValue: Double? = {
                if let ti = timestampIdx, ti < metrics.count { return (metrics[ti] as? NSNumber)?.doubleValue }
                return nil
            }()

            guard let power = powerValue else {
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
            current.append(power)
            previousTimestamp = timestampValue
        }
        if !current.isEmpty { segments.append(current) }
        return segments
    }

    /// Return the best rolling average for each requested duration.
    static func bestRollingAverages(_ samples: [Double], durations: [Int]) -> [Int: Double] {
        guard !samples.isEmpty else { return [:] }
        var prefix: [Double] = [0]
        for s in samples { prefix.append(prefix[prefix.count - 1] + s) }
        let n = samples.count
        var best: [Int: Double] = [:]
        for d in durations where n >= d {
            var maxAvg = -Double.greatestFiniteMagnitude
            for i in 0...(n - d) {
                let avg = (prefix[i + d] - prefix[i]) / Double(d)
                if avg > maxAvg { maxAvg = avg }
            }
            best[d] = maxAvg
        }
        return best
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
