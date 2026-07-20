import AppIntents
import Foundation

// MARK: - Planned workout entity
//
// Value bridge between a planned `WorkoutRecord` and the App Intents layer —
// what Siri resolves, displays, and passes into the workout intents. The
// record stays the source of truth; the entity is a display/id snapshot.

struct PlannedWorkoutEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Planned Workout"
    static let defaultQuery = PlannedWorkoutQuery()

    var id: String

    @Property(title: "Name")
    var name: String

    @Property(title: "Sport")
    var sport: String

    @Property(title: "Date")
    var date: Date

    @Property(title: "Summary")
    var summary: String

    @MainActor
    init(record: WorkoutRecord) {
        id = record.id
        name = record.name
        sport = record.family.displayName
        date = record.date
        summary = record.plannedSummaryLine()
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: "\(sport) • \(date.formatted(date: .abbreviated, time: .omitted)) • \(summary)"
        )
    }
}

struct PlannedWorkoutQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [PlannedWorkoutEntity] {
        identifiers.compactMap { id in
            TrainingDataStore.shared.scheduledWorkout(id: id).map { PlannedWorkoutEntity(record: $0) }
        }
    }

    /// Open plans over the next 14 days — the set Siri resolves references like
    /// "my Thursday ride" against.
    @MainActor
    func suggestedEntities() async throws -> [PlannedWorkoutEntity] {
        let today = Calendar.current.startOfDay(for: .now)
        return TrainingDataStore.shared
            .openScheduledWorkouts(from: today, to: today.addingTimeInterval(13 * 86_400))
            .map { PlannedWorkoutEntity(record: $0) }
    }
}
