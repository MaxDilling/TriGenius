import SwiftUI

// MARK: - Recorded strength sets editor
//
// Corrects what the watch recorded, set by set — exercise, reps, weight, time,
// rest; sets can be added, removed and reordered. Saving replaces the recorded
// list through the override layer (`overrideStrengthSets`), so a resync keeps it.

struct StrengthSetsEditorSheet: View {
    let activityId: String
    @State private var sets: [EditableSet]
    @Environment(\.dismiss) private var dismiss

    private struct EditableSet: Identifiable {
        let id = UUID()
        var row: StrengthSets.SetRow
    }

    init(activityId: String, rows: [StrengthSets.SetRow]) {
        self.activityId = activityId
        _sets = State(initialValue: rows.map { EditableSet(row: $0) })
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach($sets) { $set in
                        NavigationLink {
                            SetEditorView(row: $set.row)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(set.row.title)
                                Text(Self.summary(set.row))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        // macOS has no swipe-to-delete or drag-to-reorder (see `reorderButtons`).
                        .contextMenu {
                            reorderButtons($sets, id: set.id)
                            Button("Delete", role: .destructive) { sets.removeAll { $0.id == set.id } }
                        }
                    }
                    .onDelete { sets.remove(atOffsets: $0) }
                    .onMove { sets.move(fromOffsets: $0, toOffset: $1) }
                    Button("Add set") { sets.append(EditableSet(row: sets.last?.row ?? StrengthSets.SetRow())) }
                } footer: {
                    Text("Your corrections replace what the watch recorded and stay through every sync.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Edit Sets")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        TrainingDataStore.shared.overrideStrengthSets(activityId: activityId,
                                                                      exercises: StrengthSets.entries(sets.map(\.row)))
                        dismiss()
                    }
                    .disabled(sets.isEmpty)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 560)
        #endif
    }

    private static func summary(_ row: StrengthSets.SetRow) -> String {
        let load = ExerciseSetsCard.load(row)
        var parts = [row.reps.map { "\($0) reps" } ?? "– reps", row.weightKg == nil ? load : "\(load) kg"]
        if let seconds = row.seconds { parts.append(ExerciseSetsCard.time(seconds)) }
        if let rest = row.restSeconds { parts.append("rest \(ExerciseSetsCard.time(rest))") }
        return parts.joined(separator: " · ")
    }
}

private struct SetEditorView: View {
    @Binding var row: StrengthSets.SetRow
    @State private var showingExercisePicker = false

    var body: some View {
        Form {
            Button {
                showingExercisePicker = true
            } label: {
                LabeledContent("Exercise", value: row.title)
            }
            .buttonStyle(.plain)
            numberField("Reps", value: $row.reps, format: .number, prompt: "none")
            numberField("Weight (kg)", value: $row.weightKg, format: .number, prompt: "bodyweight")
            mmssField("Time", seconds: $row.seconds)
            mmssField("Rest after", seconds: $row.restSeconds)
        }
        .formStyle(.grouped)
        .navigationTitle("Set")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .exercisePicker(
            isPresented: $showingExercisePicker,
            // Garmin's key beside the library id: an edited set keeps the
            // recorded shape (`StrengthSets.SetRow.exerciseName`).
            onSelectLibrary: { exercise in
                row.exerciseId = exercise.id
                row.exerciseName = exercise.garminName ?? exercise.name
                row.exerciseCategory = exercise.garminCategory
            },
            onSelectCustom: { name in
                row.exerciseId = nil
                row.exerciseName = name
                row.exerciseCategory = nil
            }
        )
    }
}
