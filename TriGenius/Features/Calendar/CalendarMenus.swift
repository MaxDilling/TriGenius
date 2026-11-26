import SwiftUI
#if os(macOS)
import AppKit
#endif

// MARK: - Calendar menus
//
// The calendar's planning actions, shared by the "+" menu, a day's context menu
// and a workout's. Each menu is its own view, so it observes `viewModel` itself
// and stays current inside the `Equatable` cells that skip re-rendering.

/// One button per sport, in the editor's order.
struct SportMenuItems: View {
    let action: (EditorSport) -> Void

    var body: some View {
        ForEach(EditorSport.allCases) { sport in
            Button(sport.label, systemImage: sport.family.icon) { action(sport) }
        }
    }
}

/// A day's own actions: a new plan per sport, the library, the copied workout.
struct DayMenu: View {
    let viewModel: CalendarViewModel
    let day: Date

    var body: some View {
        Menu("New Workout", systemImage: "plus") {
            SportMenuItems { viewModel.newPlan(on: day, sport: $0) }
        }
        Button("From Library…", systemImage: "square.stack") { viewModel.openLibrary(on: day) }
        Button("Paste", systemImage: "doc.on.clipboard") {
            if let seed = viewModel.copied { viewModel.plan(seed, on: day) }
        }
        .disabled(viewModel.copied == nil)
    }
}

/// A workout's actions. A race slot follows its ATP event, so it has none; an
/// adaptive suggestion can be repeated but not changed.
struct WorkoutMenu: View {
    let viewModel: CalendarViewModel
    let record: WorkoutRecord

    var body: some View {
        if record.source != TrainingDataStore.raceSource {
            let editable = !record.isCompleted && !record.isReadOnly
            if editable {
                Button("Edit", systemImage: "pencil") { viewModel.editor = .edit(record) }
            }
            // A plan or a strength session can repeat (`templateData`). The seed is
            // built on use: a completed row's details are too costly to parse per chip.
            if record.isPlanned || SportFamily(sportKey: record.sport) == .strength {
                if !record.isCompleted {
                    Button("Duplicate", systemImage: "plus.square.on.square") {
                        withSeed { viewModel.plan($0, on: record.date) }
                    }
                }
                Button("Copy", systemImage: "doc.on.doc") { withSeed { viewModel.copied = $0 } }
                Button("Save as Template", systemImage: "square.stack") {
                    withSeed { viewModel.templateSave = TrainingDataStore.shared.saveTemplate($0.workoutData) }
                }
            }
            if editable {
                Divider()
                Button("Delete", systemImage: "trash", role: .destructive) {
                    Task { await DataSyncCoordinator.shared.deletePlan(id: record.id) }
                }
            }
        }
    }

    /// Only a strength session without recorded sets has no seed.
    private func withSeed(_ use: (PlanSeed) -> Void) {
        guard let seed = PlanSeed(record) else {
            viewModel.planRejection = ["This session has no recorded sets to repeat."]
            return
        }
        use(seed)
    }
}

/// ⌥ held as a workout is dropped copies it instead of moving it, as in the Finder.
var dropCopies: Bool {
    #if os(macOS)
    NSEvent.modifierFlags.contains(.option)
    #else
    false
    #endif
}
