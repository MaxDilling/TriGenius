import SwiftUI

/// A stored workout's detail, resolved when it is opened — completed first, so a
/// finished (folded) plan opens the actual session.
struct WorkoutDetailDestination: View {
    let id: String

    var body: some View {
        if let record = TrainingDataStore.shared.activity(id: id) {
            TrainingDetailView(record: record)
        } else if let plan = TrainingDataStore.shared.scheduledWorkout(id: id) {
            PlannedWorkoutDetailView(workout: plan)
        } else {
            ContentUnavailableView("Workout no longer available", systemImage: "calendar.badge.minus")
        }
    }
}
