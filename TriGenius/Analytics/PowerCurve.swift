import Foundation

// MARK: - Cycling power curve (max mean power per duration)
//
// The single power-duration-curve implementation. Sources shape their raw power
// stream into contiguous 1 Hz segments (split on recording gaps); `maxMeans`
// computes the best rolling average per grid duration at ingest and the encoded
// result is stored in `WorkoutRecord.powerCurveJSON`. The Statistics chart and
// the coach's `get_power_curve` read back the stored per-activity curves via
// `aggregate` — the element-wise max over a date range, with each point
// attributed to the activity that set it.

enum PowerCurve {

    /// Fixed log-spaced duration grid (seconds), 1 s – 6 h. Durations beyond an
    /// activity's longest contiguous segment get no entry — absence, never a
    /// substitute.
    nonisolated static let durations: [Int] = [
        1, 2, 3, 5, 8, 10, 15, 20, 30, 45, 60, 90, 120, 150, 180, 240, 300,
        420, 600, 900, 1200, 1800, 2400, 3600, 5400, 7200, 10800, 14400, 18000, 21600
    ]

    /// Best rolling mean (watts) per grid duration over contiguous 1 Hz segments.
    /// A window never spans a segment boundary (recording gap). Prefix sums make
    /// each duration a single O(n) sweep.
    nonisolated static func maxMeans(segments: [[Double]]) -> [Int: Double] {
        var best: [Int: Double] = [:]
        for samples in segments where !samples.isEmpty {
            var prefix: [Double] = [0]
            prefix.reserveCapacity(samples.count + 1)
            for s in samples { prefix.append(prefix[prefix.count - 1] + s) }
            let n = samples.count
            for d in durations where n >= d {
                var maxSum = -Double.greatestFiniteMagnitude
                for i in 0...(n - d) {
                    let sum = prefix[i + d] - prefix[i]
                    if sum > maxSum { maxSum = sum }
                }
                let avg = maxSum / Double(d)
                if avg > best[d] ?? -Double.greatestFiniteMagnitude { best[d] = avg }
            }
        }
        return best
    }

    // MARK: `powerCurveJSON` codec

    /// `[[duration,watts],…]` ascending, watts to 0.1 W; `""` for no curve.
    nonisolated static func encode(_ curve: [Int: Double]) -> String {
        guard !curve.isEmpty else { return "" }
        let pairs: [[Any]] = curve.keys.sorted().map { [$0, (curve[$0]! * 10).rounded() / 10] }
        return String(compactJSON: pairs)
    }

    nonisolated static func decode(_ json: String) -> [Int: Double] {
        guard !json.isEmpty, let data = json.data(using: .utf8),
              let pairs = try? JSONSerialization.jsonObject(with: data) as? [[Double]]
        else { return [:] }
        var curve: [Int: Double] = [:]
        for pair in pairs where pair.count == 2 { curve[Int(pair[0])] = pair[1] }
        return curve
    }

    // MARK: Range aggregation

    /// One aggregated point and the activity that set it.
    struct Point: Codable, Equatable, Identifiable {
        nonisolated var id: Int { durationSeconds }
        let durationSeconds: Int
        let watts: Double
        let activityId: String
        let activityName: String
        let date: Date
    }

    /// Element-wise max across per-activity curves, ascending by duration.
    nonisolated static func aggregate(
        _ curves: [(id: String, name: String, date: Date, curve: [Int: Double])]
    ) -> [Point] {
        var best: [Int: Point] = [:]
        for activity in curves {
            for (duration, watts) in activity.curve where watts > best[duration]?.watts ?? 0 {
                best[duration] = Point(durationSeconds: duration, watts: watts,
                                       activityId: activity.id, activityName: activity.name,
                                       date: activity.date)
            }
        }
        return best.values.sorted { $0.durationSeconds < $1.durationSeconds }
    }

    /// Aggregate the stored curves of the given records (rows without a power
    /// stream carry `""` and contribute nothing).
    @MainActor
    static func aggregate(records: [WorkoutRecord]) -> [Point] {
        aggregate(records.compactMap { record in
            let curve = decode(record.powerCurveJSON)
            return curve.isEmpty ? nil : (record.id, record.name, record.date, curve)
        })
    }

    /// Compact duration label, exact for non-round grid points ("1m30s", not "1m").
    nonisolated static func durationLabel(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 {
            let m = seconds / 60, s = seconds % 60
            return s == 0 ? "\(m)m" : "\(m)m\(s)s"
        }
        let h = seconds / 3600, m = (seconds % 3600) / 60
        return m == 0 ? "\(h)h" : "\(h)h\(m)m"
    }
}
