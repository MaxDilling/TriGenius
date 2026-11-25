import Foundation
import SwiftData

// MARK: - Workout templates
//
// The athlete's workout library: a workout without a date, kept as the
// normalized `workout_data` a plan is written from — scheduling one is
// `addPlan` with that dict, and the editor opens it like any plan. Mirrors into
// CloudKit with the rest of the store (`deduplicate()` merges on `id`).

@Model
final class WorkoutTemplate {
    var id: String = ""
    var name: String = ""
    var sport: String = ""
    var workoutDataJSON: String = "{}"
    var updatedAt: Date = Date.distantPast

    init() {
        id = UUID().uuidString
    }

    @MainActor var workoutData: [String: Any] { WorkoutPayloadBuilder.parseWorkoutData(workoutDataJSON) ?? [:] }
    var family: SportFamily { SportFamily(sportKey: sport) }

    /// What a library row carries when dragged onto a calendar day — a workout
    /// chip's drag carries its plan id, so the prefix tells the two apart.
    static let dragPrefix = "template:"
    var dragID: String { Self.dragPrefix + id }
}

extension TrainingDataStore {
    func template(dragID: String) -> WorkoutTemplate? {
        guard dragID.hasPrefix(WorkoutTemplate.dragPrefix) else { return nil }
        let id = String(dragID.dropFirst(WorkoutTemplate.dragPrefix.count))
        return try? container.mainContext.fetch(FetchDescriptor<WorkoutTemplate>(predicate: #Predicate { $0.id == id })).first
    }

    /// Store `workoutData` as a template — new, or `template` replaced — after
    /// the same normalization and plausibility check a plan gets. The errors
    /// that rejected it; empty when saved.
    func saveTemplate(_ workoutData: [String: Any], replacing template: WorkoutTemplate? = nil) -> [String] {
        let (data, _, errors) = WorkoutNormalizer.normalize(workoutData)
        guard errors.isEmpty else { return errors }
        let row = template ?? WorkoutTemplate()
        if template == nil { container.mainContext.insert(row) }
        row.name = data["name"] as? String ?? ""
        row.sport = data["sport"] as? String ?? ""
        row.workoutDataJSON = WorkoutPayloadBuilder.workoutDataJSON(data)
        row.updatedAt = .now
        try? container.mainContext.save()
        return []
    }

    func deleteTemplate(_ template: WorkoutTemplate) {
        container.mainContext.delete(template)
        try? container.mainContext.save()
    }
}
