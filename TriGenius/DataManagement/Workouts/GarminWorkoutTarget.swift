import Foundation

// MARK: - Garmin write target
//
// Thin adapter over the existing `GarminService` workout CRUD (which builds the
// Garmin payload via `GarminWorkoutBuilder` and schedules to a date). It only
// translates `GarminService`'s "✓/✗ message\n<json>" string results into a
// `WorkoutWriteResult`, extracting the Garmin `workout_id` as the external ref.

@MainActor
struct GarminWorkoutTarget: WorkoutSyncTarget {
    let target: WriteTarget = .garmin
    private let service = GarminService.shared

    var isAvailable: Bool {
        get async { await GarminAuth.shared.isAuthenticated }
    }

    func schedule(_ workout: PlannedWorkout) async -> WorkoutWriteResult {
        guard await isAvailable else { return .failure("Garmin is not connected.") }
        return Self.parse(await service.addWorkout(workoutData: workout.workoutData, date: workout.date))
    }

    func update(externalId: String, _ workout: PlannedWorkout) async -> WorkoutWriteResult {
        guard await isAvailable else { return .failure("Garmin is not connected.") }
        return Self.parse(await service.modifyWorkout(workoutId: externalId, workoutData: workout.workoutData))
    }

    func move(externalId: String, to date: String, from: String?) async -> WorkoutWriteResult {
        guard await isAvailable else { return .failure("Garmin is not connected.") }
        return Self.parse(await service.moveWorkout(workoutId: externalId, toDate: date, fromDate: from))
    }

    func delete(externalId: String) async -> WorkoutWriteResult {
        guard await isAvailable else { return .failure("Garmin is not connected.") }
        return Self.parse(await service.deleteWorkout(workoutId: externalId))
    }

    /// Map a `GarminService` "✓/✗ <msg>\n<json>" result to a `WorkoutWriteResult`,
    /// pulling out `workout_id` when present.
    private static func parse(_ result: String) -> WorkoutWriteResult {
        let ok = result.hasPrefix("✓")
        var externalId: String?
        if let brace = result.firstIndex(of: "{"),
           let data = String(result[brace...]).data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let wid = obj["workout_id"], !(wid is NSNull) {
            externalId = "\(wid)"
        }
        let firstLine = result.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? result
        return WorkoutWriteResult(success: ok, externalId: externalId, message: firstLine)
    }
}
