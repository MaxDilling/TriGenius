import SwiftUI

// MARK: - Recorded strength sets editor
//
// Corrects what the watch recorded — or what the athlete logged live — one
// section per exercise: its sets edited in place (reps, weight, time, rest),
// and the exercise itself re-matched for every set at once, e.g. a custom name
// typed live to the library exercise it meant. Saving replaces the recorded
// list through the override layer (`overrideStrengthSets`), so a resync keeps it.

struct StrengthSetsEditorSheet: View {
    let activityId: String
    @State private var sets: [EditableSet]
    /// The first set of the exercise being re-matched; nil while adding.
    @State private var rematching: UUID?
    @State private var picking = false
    @Environment(\.dismiss) private var dismiss

    private struct EditableSet: Identifiable {
        let id = UUID()
        var row: StrengthSets.SetRow
    }

    init(activityId: String, rows: [StrengthSets.SetRow]) {
        self.activityId = activityId
        _sets = State(initialValue: rows.map { EditableSet(row: $0) })
    }

    /// Consecutive sets of one exercise.
    private var groups: [[EditableSet]] {
        sets.reduce(into: []) { groups, set in
            if let last = groups.last?.last, last.row.sameExercise(as: set.row) {
                groups[groups.count - 1].append(set)
            } else {
                groups.append([set])
            }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                ForEach(groups, id: \.first?.id) { group in
                    Section {
                        exerciseRow(group)
                        columnHeader
                        ForEach(Array(group.enumerated()), id: \.element.id) { index, set in
                            setRow(number: index + 1, binding(set.id))
                                .contextMenu {
                                    Button("Delete", systemImage: "trash", role: .destructive) { sets.removeAll { $0.id == set.id } }
                                }
                        }
                        .onDelete { offsets in
                            let ids = Set(offsets.map { group[$0].id })
                            sets.removeAll { ids.contains($0.id) }
                        }
                        Button("Add Set", systemImage: "plus") {
                            guard let last = group.last, let index = sets.firstIndex(where: { $0.id == last.id }) else { return }
                            sets.insert(EditableSet(row: last.row), at: index + 1)
                        }
                        .buttonStyle(.borderless)
                    }
                }
                Section {
                    Button("Add Exercises", systemImage: "plus") {
                        rematching = nil
                        picking = true
                    }
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
            .exercisePicker(isPresented: $picking, multiple: rematching == nil, query: rematchQuery, onPick: picked)
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 560)
        #endif
    }

    // MARK: Rows

    /// The exercise, tapped to re-match all its sets; dragged onto another
    /// exercise to move the whole group there.
    private func exerciseRow(_ group: [EditableSet]) -> some View {
        let row = group[0].row
        let exercise = row.exerciseId.flatMap(ExerciseLibrary.find(id:)) ?? row.exerciseName.flatMap(ExerciseLibrary.find(garminName:))
        return Button {
            rematching = group[0].id
            picking = true
        } label: {
            HStack(spacing: Theme.Spacing.m) {
                ExerciseThumbnail(exercise: exercise)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title).font(.headline)
                    if exercise == nil {
                        Text("Custom exercise · tap to match it to the library").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                Chevron()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .draggable(group[0].id.uuidString)
        .dropDestination(for: String.self) { dropped, _ in
            guard let moved = dropped.first.flatMap(UUID.init(uuidString:)) else { return false }
            moveGroup(moved, to: group[0].id)
            return true
        }
    }

    private var columnHeader: some View {
        HStack(spacing: Theme.Spacing.s) {
            Text("Set").frame(width: 28, alignment: .leading)
            ForEach(["Reps", "kg", "Time", "Rest"], id: \.self) { Text($0).frame(maxWidth: .infinity) }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func setRow(number: Int, _ set: Binding<StrengthSets.SetRow>) -> some View {
        HStack(spacing: Theme.Spacing.s) {
            Text("\(number)").foregroundStyle(.secondary).frame(width: 28, alignment: .leading)
            cell(TextField("", value: set.reps, format: .number, prompt: Text("–")))
            cell(TextField("", value: set.weightKg, format: .number, prompt: Text("BW")))
            cell(TextField("", text: mmss(set.seconds), prompt: Text("–")))
            cell(TextField("", text: mmss(set.restSeconds), prompt: Text("–")))
        }
        .monospacedDigit()
    }

    private func cell(_ field: some View) -> some View {
        field
            .textFieldStyle(.plain)
            .multilineTextAlignment(.center)
            .labelsHidden()
            .padding(.vertical, Theme.Spacing.xs)
            .frame(maxWidth: .infinity)
            .background(Color.appTertiaryBackground, in: .rect(cornerRadius: Theme.Radius.s))
            #if os(iOS)
            .keyboardType(.numbersAndPunctuation)
            #endif
    }

    /// Optional seconds as "m:ss"; unparseable input clears them.
    private func mmss(_ seconds: Binding<Double?>) -> Binding<String> {
        Binding(get: { seconds.wrappedValue.map { MMSS.format(Int($0.rounded())) } ?? "" },
                set: { seconds.wrappedValue = MMSS.parse($0).map(Double.init) })
    }

    private func binding(_ id: UUID) -> Binding<StrengthSets.SetRow> {
        Binding(get: { sets.first { $0.id == id }?.row ?? StrengthSets.SetRow() },
                set: { new in if let i = sets.firstIndex(where: { $0.id == id }) { sets[i].row = new } })
    }

    // MARK: Edits

    /// A custom name searches the library for what it meant.
    private var rematchQuery: String {
        guard let id = rematching, let row = sets.first(where: { $0.id == id })?.row,
              row.exerciseId == nil, row.exerciseCategory == nil else { return "" }
        return row.exerciseName ?? ""
    }

    /// Re-matches every set of the group, or appends one set per new exercise.
    /// A library exercise keeps Garmin's key beside its id, so an edited set
    /// keeps the recorded shape (`StrengthSets.SetRow.exerciseName`).
    private func picked(_ choices: [ExerciseChoice]) {
        func apply(_ choice: ExerciseChoice, to row: inout StrengthSets.SetRow) {
            switch choice {
            case .library(let exercise):
                row.exerciseId = exercise.id
                row.exerciseName = exercise.garminName ?? exercise.name
                row.exerciseCategory = exercise.garminCategory
            case .custom(let name):
                row.exerciseId = nil
                row.exerciseName = name
                row.exerciseCategory = nil
            }
        }
        guard let rematching else {
            for choice in choices {
                var row = StrengthSets.SetRow()
                apply(choice, to: &row)
                sets.append(EditableSet(row: row))
            }
            return
        }
        guard let choice = choices.first, let group = groups.first(where: { $0.first?.id == rematching }) else { return }
        let ids = Set(group.map(\.id))
        for i in sets.indices where ids.contains(sets[i].id) { apply(choice, to: &sets[i].row) }
    }

    private func moveGroup(_ moved: UUID, to target: UUID) {
        var reordered = groups
        guard let from = reordered.firstIndex(where: { $0.first?.id == moved }),
              let to = reordered.firstIndex(where: { $0.first?.id == target }), from != to else { return }
        reordered.insert(reordered.remove(at: from), at: to)
        sets = reordered.flatMap { $0 }
    }
}
