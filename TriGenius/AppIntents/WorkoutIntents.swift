import AppIntents
import Foundation

// MARK: - Workout intents
//
// Siri's window onto the training plan. Reads go through `TrainingDataStore`,
// writes through `DataSyncCoordinator`'s plan CRUD — the same single write path
// the coach tools and the workout editor use, so Siri writes get the identical
// normalization, plausibility rejection, and write-target push.

/// The sports a Siri-scheduled workout can carry, mapped to the same
/// `workout_data` sport keys the coach's `add_workouts` tool uses.
enum WorkoutSport: String, AppEnum {
    case swim, bike, run, strength

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Sport"
    static let caseDisplayRepresentations: [WorkoutSport: DisplayRepresentation] = [
        .swim: "Swim", .bike: "Bike", .run: "Run", .strength: "Strength",
    ]

    var sportKey: String {
        switch self {
        case .swim: "swimming"
        case .bike: "cycling"
        case .run: "running"
        case .strength: "strength"
        }
    }
}

enum WorkoutIntentError: Error, CustomLocalizedStringResourceConvertible {
    case planNotFound
    case rejected(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .planNotFound: "That planned workout no longer exists."
        case .rejected(let reasons): "The workout couldn't be scheduled: \(reasons)"
        }
    }
}

struct GetPlannedWorkoutsIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Planned Workouts"
    static let description = IntentDescription(
        "Lists the outstanding planned workouts for a day, or for the next 7 days."
    )

    @Parameter(title: "Day", description: "The day to look up. Leave empty for the next 7 days.")
    var day: Date?

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[PlannedWorkoutEntity]> & ProvidesDialog {
        let cal = Calendar.current
        let from: Date, to: Date, label: String
        if let day {
            from = cal.startOfDay(for: day)
            to = from
            label = from.formatted(date: .complete, time: .omitted)
        } else {
            from = cal.startOfDay(for: .now)
            to = from.addingTimeInterval(6 * 86_400)
            label = "the next 7 days"
        }
        let entities = TrainingDataStore.shared
            .openScheduledWorkouts(from: from, to: to)
            .map { PlannedWorkoutEntity(record: $0) }
        guard !entities.isEmpty else {
            return .result(value: [], dialog: "No planned workouts for \(label).")
        }
        let lines = entities.map {
            "\($0.name) (\($0.sport), \($0.date.formatted(date: .abbreviated, time: .omitted)), \($0.summary))"
        }
        return .result(
            value: entities,
            dialog: "\(entities.count) planned workout\(entities.count == 1 ? "" : "s") for \(label): \(lines.joined(separator: "; "))."
        )
    }
}

struct ScheduleWorkoutIntent: AppIntent {
    static let title: LocalizedStringResource = "Schedule Workout"
    static let description = IntentDescription(
        "Adds a simple planned workout (sport, day, duration) to the training calendar."
    )

    @Parameter(title: "Sport")
    var sport: WorkoutSport

    @Parameter(title: "Day")
    var day: Date

    @Parameter(title: "Duration (minutes)", inclusiveRange: (1, 2880))
    var minutes: Int

    @Parameter(title: "Name")
    var name: String?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        var workoutData: [String: Any] = ["sport": sport.sportKey, "duration_minutes": minutes]
        if let name { workoutData["name"] = name }
        let date = Calendar.current.startOfDay(for: day)
        switch await DataSyncCoordinator.shared.addPlan(workoutData: workoutData, date: date) {
        case .success(let outcome):
            let push = outcome.pushed ? ", sent to \(outcome.targetName)" : ""
            return .result(dialog: "Scheduled \(outcome.name) for \(date.formatted(date: .abbreviated, time: .omitted))\(push).")
        case .rejected(let reasons):
            throw WorkoutIntentError.rejected(reasons.joined(separator: " "))
        }
    }
}

struct MovePlannedWorkoutIntent: AppIntent {
    static let title: LocalizedStringResource = "Move Planned Workout"
    static let description = IntentDescription("Moves a planned workout to another day.")

    @Parameter(title: "Workout")
    var workout: PlannedWorkoutEntity

    @Parameter(title: "New Day")
    var day: Date

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let date = Calendar.current.startOfDay(for: day)
        guard let outcome = await DataSyncCoordinator.shared.movePlan(id: workout.id, to: date) else {
            throw WorkoutIntentError.planNotFound
        }
        let push = outcome.pushed ? "" : " (not yet synced to \(outcome.targetName))"
        return .result(dialog: "Moved \(outcome.name) to \(date.formatted(date: .abbreviated, time: .omitted))\(push).")
    }
}

struct DeletePlannedWorkoutIntent: AppIntent {
    static let title: LocalizedStringResource = "Delete Planned Workout"
    static let description = IntentDescription(
        "Deletes a planned workout from the training calendar and every synced device."
    )

    @Parameter(title: "Workout")
    var workout: PlannedWorkoutEntity

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await requestConfirmation(
            dialog: "Delete \"\(workout.name)\" on \(workout.date.formatted(date: .abbreviated, time: .omitted))?"
        )
        await DataSyncCoordinator.shared.deletePlan(id: workout.id)
        return .result(dialog: "Deleted \(workout.name).")
    }
}
