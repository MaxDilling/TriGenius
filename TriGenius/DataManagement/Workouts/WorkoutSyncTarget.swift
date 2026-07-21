import Foundation

// MARK: - Workout write-target abstraction
//
// The coach has exactly ONE set of scheduling tools (add/modify/move/delete); they
// route to whichever provider the athlete picked as their `WriteTarget`. Planned
// workouts are owned locally (the `WorkoutRecord` store is the source of truth) and
// pushed to the active target, which returns a provider-specific external id stored
// on the record. New providers implement `WorkoutSyncTarget` and add a `WriteTarget`
// case — the coach tools and the local store don't change.

/// A normalized planned workout ready to be written to a provider. `workoutData`
/// is the canonical (already `WorkoutNormalizer`-normalized) `workout_data` dict
/// shared by every backend.
struct PlannedWorkout {
    let workoutData: [String: Any]
    /// Target date, YYYY-MM-DD.
    let date: String

    var sport: String { Coerce.token(workoutData["sport"] as? String, default: "other") }
    var name: String { workoutData["name"] as? String ?? "Workout" }
}

/// Outcome of a write to a provider.
struct WorkoutWriteResult {
    let success: Bool
    /// The provider's id for the scheduled workout, when it assigns one.
    let externalId: String?
    /// Human-readable single line for the coach to relay.
    let message: String

    static func failure(_ message: String) -> WorkoutWriteResult {
        WorkoutWriteResult(success: false, externalId: nil, message: message)
    }
}

/// A destination the coach can schedule planned workouts to. All methods run on the
/// MainActor (they touch provider services that are MainActor-bound).
@MainActor
protocol WorkoutSyncTarget {
    var target: WriteTarget { get }
    /// Whether this target can currently be written to (e.g. Garmin connected,
    /// WorkoutKit authorized + on a supported platform).
    var isAvailable: Bool { get async }

    func schedule(_ workout: PlannedWorkout) async -> WorkoutWriteResult
    func update(externalId: String, _ workout: PlannedWorkout) async -> WorkoutWriteResult
    func move(externalId: String, to date: String, from: String?) async -> WorkoutWriteResult
    func delete(externalId: String) async -> WorkoutWriteResult

    /// Remove every workout this target has scheduled whose external id is *not* in
    /// `keeping` — orphans left when a plan was deleted through a path other than
    /// `delete`, or when a store reset lost the refs. Reconciliation passes the live
    /// set of local-plan refs; the target prunes the rest of its own schedule.
    func prune(keeping liveExternalIds: Set<String>) async
}

extension WorkoutSyncTarget {
    /// Default opt-out: a target that can't enumerate its own schedule, or whose
    /// provider copy is authoritative rather than mirror-of-local (Garmin), does not
    /// prune.
    func prune(keeping liveExternalIds: Set<String>) async {}
}

/// Builds the active `WorkoutSyncTarget` for the athlete's chosen write target.
@MainActor
enum WorkoutTargetFactory {
    static func make(_ target: WriteTarget) -> WorkoutSyncTarget {
        switch target {
        case .garmin:
            return GarminWorkoutTarget()
        case .appleWatch:
            #if os(iOS)
            return AppleWatchWorkoutTarget()
            #else
            return UnavailableWorkoutTarget(target: .appleWatch)
            #endif
        }
    }
}

/// Stand-in for a target unavailable on the current platform (e.g. Apple Watch on
/// macOS). Keeps call sites platform-agnostic; every write reports unavailability.
@MainActor
struct UnavailableWorkoutTarget: WorkoutSyncTarget {
    let target: WriteTarget
    var isAvailable: Bool { get async { false } }
    private var note: String { "\(target.displayName) isn't available on this device." }
    func schedule(_ workout: PlannedWorkout) async -> WorkoutWriteResult { .failure(note) }
    func update(externalId: String, _ workout: PlannedWorkout) async -> WorkoutWriteResult { .failure(note) }
    func move(externalId: String, to date: String, from: String?) async -> WorkoutWriteResult { .failure(note) }
    func delete(externalId: String) async -> WorkoutWriteResult { .failure(note) }
}
