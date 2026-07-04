import Foundation

// MARK: - Workout diff
//
// Field-level "old → new" lines between two canonical `workout_data` dicts
// (`WorkoutPayloadBuilder.workoutData`), feeding the chat's modified-workout
// card. Always compares the *stored* before/after states — never the coach's
// request — so the card shows what actually applied after `WorkoutNormalizer`.
// All value formatting defers to `PlannedWorkoutFormat`, so a diff line reads
// exactly like the same value on the detail views.

enum WorkoutDiff {

    static func changes(before: [String: Any], after: [String: Any]) -> [String] {
        var lines: [String] = []
        text("Name", "name", before, after, into: &lines)
        text("Sport", "sport", before, after, into: &lines)
        number("Duration", "duration_minutes", before, after, into: &lines) { durationHM($0) }
        number("Distance", "distance_meters", before, after, into: &lines) { PlannedWorkoutFormat.distance($0) }
        number("Pool", "pool_length", before, after, into: &lines) { "\(Int($0.rounded())) m" }
        if (before["description"] as? String ?? "") != (after["description"] as? String ?? "") {
            lines.append("Description updated")
        }
        // The post-edit sport keys the pace/cadence units in step targets.
        let family = SportFamily(sportKey: after["sport"] as? String ?? "")
        lines += stepChanges(before["steps"] as? [[String: Any]] ?? [],
                             after["steps"] as? [[String: Any]] ?? [],
                             family: family)
        if lines.count > 6 {
            lines = Array(lines.prefix(5)) + ["+\(lines.count - 5) more"]
        }
        return lines
    }

    // MARK: Scalars

    private static func text(_ label: String, _ key: String,
                             _ before: [String: Any], _ after: [String: Any], into lines: inout [String]) {
        let b = before[key] as? String ?? ""
        let a = after[key] as? String ?? ""
        guard b != a else { return }
        lines.append("\(label): \(b.isEmpty ? "—" : b) → \(a.isEmpty ? "—" : a)")
    }

    private static func number(_ label: String, _ key: String,
                               _ before: [String: Any], _ after: [String: Any], into lines: inout [String],
                               format: (Double) -> String) {
        let b = (before[key] as? NSNumber)?.doubleValue
        let a = (after[key] as? NSNumber)?.doubleValue
        guard b != a else { return }
        lines.append("\(label): \(b.map(format) ?? "—") → \(a.map(format) ?? "—")")
    }

    // MARK: Steps

    /// Per-index comparison when the counts match (recursing one level into
    /// repeat-block children); a single structural line otherwise.
    private static func stepChanges(_ before: [[String: Any]], _ after: [[String: Any]],
                                    family: SportFamily) -> [String] {
        guard (before as NSArray) != (after as NSArray) else { return [] }
        guard before.count == after.count, !before.isEmpty else {
            return ["Structure: \(before.count) → \(after.count) steps"]
        }
        var lines: [String] = []
        for (i, (b, a)) in zip(before, after).enumerated() {
            let label = "Step \(i + 1)"
            lines += fieldChanges(b, a, label: label, family: family)
            let bc = b["repeat_steps"] as? [[String: Any]] ?? []
            let ac = a["repeat_steps"] as? [[String: Any]] ?? []
            if bc.count == ac.count {
                for (j, (cb, ca)) in zip(bc, ac).enumerated() {
                    lines += fieldChanges(cb, ca, label: "\(label).\(j + 1)", family: family)
                }
            } else {
                lines.append("\(label): \(bc.count) → \(ac.count) steps")
            }
        }
        // The arrays differ but no displayable field moved (e.g. a step-type
        // change) — surface it rather than pretending nothing changed.
        return lines.isEmpty ? ["Structure updated"] : lines
    }

    private static func fieldChanges(_ b: [String: Any], _ a: [String: Any],
                                     label: String, family: SportFamily) -> [String] {
        var lines: [String] = []
        func pair(_ key: String) -> (Double?, Double?) {
            ((b[key] as? NSNumber)?.doubleValue, (a[key] as? NSNumber)?.doubleValue)
        }
        let (bt, at) = pair("duration_seconds")
        if bt != at {
            lines.append("\(label): \(bt.map { PlannedWorkoutFormat.duration($0) } ?? "—") → \(at.map { PlannedWorkoutFormat.duration($0) } ?? "—")")
        }
        let (bm, am) = pair("distance_meters")
        if bm != am {
            lines.append("\(label): \(bm.map { PlannedWorkoutFormat.distance($0) } ?? "—") → \(am.map { PlannedWorkoutFormat.distance($0) } ?? "—")")
        }
        let (bl, al) = pair("target_low")
        let (bh, ah) = pair("target_high")
        if bl != al || bh != ah {
            lines.append("\(label) target: \(target(b, low: bl, high: bh, family: family)) → \(target(a, low: al, high: ah, family: family))")
        }
        let (br, ar) = pair("repeat_count")
        if br != ar, let br, let ar { lines.append("\(label) repeats: \(Int(br)) → \(Int(ar))") }
        return lines
    }

    /// A step's target band formatted by its own `target_type` (each side may
    /// carry a different type) via the shared `PlannedWorkoutFormat.target`;
    /// the raw band for untyped values — still real data, just unitless.
    private static func target(_ step: [String: Any], low: Double?, high: Double?,
                               family: SportFamily) -> String {
        PlannedWorkoutFormat.target(type: step["target_type"] as? String, low: low, high: high, family: family)
            ?? band(low, high)
    }

    private static func band(_ low: Double?, _ high: Double?) -> String {
        switch (low, high) {
        case (let l?, let h?) where l != h: return "\(trim(l))–\(trim(h))"
        case (let l?, _): return trim(l)
        case (nil, let h?): return trim(h)
        default: return "—"
        }
    }

    private static func trim(_ v: Double) -> String {
        v.formatted(.number.precision(.fractionLength(0...1)))
    }
}
