import Foundation

// MARK: - Workout payload builder
//
// Reconstructs the canonical `workout_data` dict (the shape `WorkoutNormalizer`
// produces and every `WorkoutSyncTarget` consumes) from a stored `WorkoutRecord`
// plan. Shared by the coach's scheduling tools (`get_workouts`, re-pushing edits)
// and `DataSyncCoordinator.reconcileWriteTarget`, so a plan can always be
// re-materialized for any target from the local source of truth.

enum WorkoutPayloadBuilder {
    /// Build `workout_data` from a planned `WorkoutRecord`.
    static func workoutData(from rec: WorkoutRecord) -> [String: Any] {
        var d: [String: Any] = ["name": rec.name, "sport": rec.sport]
        if rec.targetDurationMinutes > 0 { d["duration_minutes"] = Int(rec.targetDurationMinutes.rounded()) }
        if rec.targetDistanceMeters > 0 { d["distance_meters"] = rec.targetDistanceMeters }
        if !rec.notes.isEmpty { d["description"] = rec.notes }
        if let pool = rec.poolLengthMeters, pool > 0 { d["pool_length"] = Int(pool.rounded()) }
        if let steps = parseSteps(rec.stepsJSON), !steps.isEmpty { d["steps"] = steps }
        return d
    }

    /// Decode a record's `stepsJSON` into the compact step dictionaries.
    static func parseSteps(_ json: String) -> [[String: Any]]? {
        guard let data = json.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        return arr
    }

    /// JSON-encode compact step dictionaries for storage in `stepsJSON`.
    static func stepsJSON(_ steps: [[String: Any]]) -> String {
        (try? JSONSerialization.data(withJSONObject: steps))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }
}
