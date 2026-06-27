#if os(iOS)
import Foundation
import WorkoutKit

// MARK: - Apple Watch write target (WorkoutKit)
//
// Schedules the coach's planned workouts onto the athlete's Apple Watch via
// `WorkoutScheduler`. The stored external id is the `WorkoutPlan` UUID, so move /
// update / delete locate the existing scheduled plan and re-issue it.

@MainActor
struct AppleWatchWorkoutTarget: WorkoutSyncTarget {
    let target: WriteTarget = .appleWatch

    var isAvailable: Bool {
        get async { await WorkoutScheduler.shared.authorizationState == .authorized }
    }

    private func ensureAuthorized() async -> Bool {
        if await WorkoutScheduler.shared.authorizationState == .authorized { return true }
        return await WorkoutScheduler.shared.requestAuthorization() == .authorized
    }

    func schedule(_ workout: PlannedWorkout) async -> WorkoutWriteResult {
        guard let custom = AppleWatchWorkoutBuilder.customWorkout(from: workout.workoutData) else {
            return .failure("\(workout.sport.capitalized) workouts can't be sent to the Apple Watch as a structured workout.")
        }
        guard await ensureAuthorized() else {
            return .failure("Apple Watch scheduling isn't authorized — enable it for TriGenius in Settings.")
        }
        guard let components = Self.dateComponents(from: workout.date) else { return .failure("Invalid date.") }
        let id = UUID()
        let plan = WorkoutPlan(.custom(custom), id: id)
        await WorkoutScheduler.shared.schedule(plan, at: components)
        return WorkoutWriteResult(success: true, externalId: id.uuidString,
                                  message: "Scheduled '\(custom.displayName ?? workout.name)' to the Apple Watch.")
    }

    func update(externalId: String, _ workout: PlannedWorkout) async -> WorkoutWriteResult {
        guard let custom = AppleWatchWorkoutBuilder.customWorkout(from: workout.workoutData) else {
            return .failure("This sport can't be sent to the Apple Watch as a structured workout.")
        }
        guard let id = UUID(uuidString: externalId), let components = Self.dateComponents(from: workout.date) else {
            return .failure("Invalid workout reference.")
        }
        guard await ensureAuthorized() else { return .failure("Apple Watch scheduling isn't authorized.") }
        await removeScheduled(id: id)
        let plan = WorkoutPlan(.custom(custom), id: id)
        await WorkoutScheduler.shared.schedule(plan, at: components)
        return WorkoutWriteResult(success: true, externalId: externalId, message: "Updated the Apple Watch workout.")
    }

    func move(externalId: String, to date: String, from: String?) async -> WorkoutWriteResult {
        guard let id = UUID(uuidString: externalId) else { return .failure("Invalid workout reference.") }
        guard let existing = await WorkoutScheduler.shared.scheduledWorkouts.first(where: { $0.plan.id == id }) else {
            return .failure("That Apple Watch workout is no longer scheduled.")
        }
        guard await ensureAuthorized(), let components = Self.dateComponents(from: date) else {
            return .failure("Apple Watch scheduling isn't authorized.")
        }
        await WorkoutScheduler.shared.remove(existing.plan, at: existing.date)
        await WorkoutScheduler.shared.schedule(existing.plan, at: components)
        return WorkoutWriteResult(success: true, externalId: externalId, message: "Moved the Apple Watch workout to \(date).")
    }

    func delete(externalId: String) async -> WorkoutWriteResult {
        guard let id = UUID(uuidString: externalId) else { return WorkoutWriteResult(success: true, externalId: nil, message: "Nothing to remove.") }
        await removeScheduled(id: id)
        return WorkoutWriteResult(success: true, externalId: nil, message: "Removed the Apple Watch workout.")
    }

    private func removeScheduled(id: UUID) async {
        for s in await WorkoutScheduler.shared.scheduledWorkouts where s.plan.id == id {
            await WorkoutScheduler.shared.remove(s.plan, at: s.date)
        }
    }

    // `scheduledWorkouts` is scoped to plans TriGenius itself scheduled, so anything
    // not in the live set is one of ours that lost its backing plan — safe to remove.
    func prune(keeping liveExternalIds: Set<String>) async {
        for s in await WorkoutScheduler.shared.scheduledWorkouts
        where !liveExternalIds.contains(s.plan.id.uuidString) {
            await WorkoutScheduler.shared.remove(s.plan, at: s.date)
        }
    }

    /// Schedule for the morning of the target day.
    private static func dateComponents(from ymd: String) -> DateComponents? {
        guard let date = DateFormatter.ymd.date(from: ymd) else { return nil }
        var c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        c.hour = 6
        return c
    }
}
#endif
