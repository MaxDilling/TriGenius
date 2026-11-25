import SwiftUI

// MARK: - Swap an exercise for today
//
// Replaces every set still to do of one exercise in one unit with another
// library exercise — what the athlete's `StrengthProfile` allows first — or a custom name
// when the search finds nothing fitting — for this session only. Candidates share
// the set's kind (reps or a hold, a stretch or not), so the prescription carries
// over unchanged; the weight starts from what the athlete lifted or planned for
// the new exercise; reps (or a hold's time) and weight can be adjusted before
// swapping. Sectioned by the tissue groups they share with the replaced one: the
// same primary groups, then any overlap, then the rest.

struct LiveSwapTarget: Identifiable {
    let id = UUID()
    let unit: Int
    let set: StrengthSets.SetRow
}

struct LiveSwapSheet: View {
    let target: LiveSwapTarget

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var sameMuscles: Bool
    @State private var equipment: Exercise.Equipment?
    @State private var selection: Exercise?
    @State private var customName: String?
    @State private var weightKg: Double?
    /// Nil keeps each set's own.
    @State private var reps: Int?
    @State private var seconds: Double?

    private let replaced: Exercise?
    private let isHold: Bool
    /// The sets the swap replaces.
    private let remaining: [StrengthSets.SetRow]

    private static let sectionTitles = [2: "Same muscles", 1: "Similar", 0: "Other"]

    init(target: LiveSwapTarget) {
        self.target = target
        replaced = target.set.exerciseId.flatMap(ExerciseLibrary.find(id:))
        isHold = target.set.reps == nil && target.set.seconds != nil
        let unit = LiveStrengthController.shared.session?.units.first { $0.id == target.unit }
        remaining = unit.map { u in u.sets[u.done...].filter { $0.sameExercise(as: target.set) } } ?? []
        _sameMuscles = State(initialValue: !(replaced?.primaryGroups.isEmpty ?? true))
    }

    /// 2 = the same primary groups, 1 = a shared primary group, 0 = none.
    private func rank(_ exercise: Exercise) -> Int {
        guard let replaced else { return 0 }
        if Set(exercise.primaryGroups) == Set(replaced.primaryGroups) { return 2 }
        return Set(exercise.primaryGroups).isDisjoint(with: replaced.primaryGroups) ? 0 : 1
    }

    /// Candidates by rank, best first, each section in the profile's order.
    private var sections: [(rank: Int, exercises: [Exercise])] {
        let profile = StrengthProfile.stored
        return Dictionary(grouping: ExerciseLibrary.all.filter(matches), by: rank)
            .filter { !sameMuscles || $0.key > 0 }
            .map { (rank: $0.key, exercises: profile.ranked($0.value)) }
            .sorted { $0.rank > $1.rank }
    }

    private func matches(_ exercise: Exercise) -> Bool {
        guard exercise.id != replaced?.id, exercise.isTimeBased == isHold,
              (exercise.category == .stretch) == (replaced?.category == .stretch) else { return false }
        if let equipment, exercise.equipment != equipment { return false }
        return query.isEmpty || exercise.name.localizedCaseInsensitiveContains(query)
    }

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        let sections = sections
        NavigationStack {
            List {
                Section { header }
                    .listRowSeparator(.hidden)
                    .listSectionSeparator(.hidden)
                ForEach(sections, id: \.rank) { section in
                    Section(Self.sectionTitles[section.rank] ?? "") {
                        ForEach(section.exercises) { row($0) }
                    }
                    .listSectionSeparator(.hidden)
                }
                if !trimmedQuery.isEmpty,
                   !sections.contains(where: { $0.exercises.contains { $0.name.caseInsensitiveCompare(trimmedQuery) == .orderedSame } }) {
                    Section("Not in the library") { customRow(trimmedQuery) }
                        .listSectionSeparator(.hidden)
                } else if sections.isEmpty {
                    Text("No exercise matches.").foregroundStyle(.secondary)
                }
            }
            .listStyle(.plain)
            .onChange(of: selection?.id) {
                weightKg = selection.flatMap { TrainingDataStore.shared.startingWeightKg(for: $0) }
            }
            .searchable(text: $query, prompt: "Search exercises")
            .navigationTitle("Swap exercise")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Swap", role: .confirm) { swap() }.disabled(selection == nil && customName == nil)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 560)
        #endif
    }

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text(target.set.title).font(.title2.bold())
            if let groups = replaced.map(groupsLine) {
                Text(groups).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        Text(carriesOver).font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
        if isHold {
            let shown = seconds ?? remaining.first?.seconds ?? 0
            Stepper("Time: \(ExerciseSetsCard.time(shown))",
                    value: Binding(get: { shown }, set: { seconds = $0 }), in: 5...600, step: 5)
        } else {
            let shown = reps ?? remaining.first?.reps ?? 0
            Stepper("Reps: \(shown)", value: Binding(get: { shown }, set: { reps = $0 }), in: 1...100)
        }
        Stepper("Load: \(LiveFormat.load(weightKg))",
                value: Binding(get: { weightKg ?? 0 }, set: { weightKg = $0 > 0 ? $0 : nil }),
                in: 0...500, step: 2.5)
            .disabled(selection == nil && customName == nil)
        ScrollView(.horizontal) {
            HStack(spacing: Theme.Spacing.s) {
                chip("Same muscles", isOn: $sameMuscles).disabled(replaced == nil)
                chip("No equipment", isOn: equipmentFilter(.bodyweight))
                chip("Machines", isOn: equipmentFilter(.machine))
            }
        }
        .scrollIndicators(.hidden)
    }

    /// One equipment filter at a time: turning one on replaces the other.
    private func equipmentFilter(_ kind: Exercise.Equipment) -> Binding<Bool> {
        Binding(get: { equipment == kind }, set: { equipment = $0 ? kind : nil })
    }

    /// "Primary: calves · Secondary: shins".
    private func groupsLine(_ exercise: Exercise) -> String {
        var parts = ["Primary: " + exercise.primaryGroups.map { $0.label.lowercased() }.joined(separator: ", ")]
        if !exercise.secondaryGroups.isEmpty {
            parts.append("Secondary: " + exercise.secondaryGroups.map { $0.label.lowercased() }.joined(separator: ", "))
        }
        return parts.joined(separator: " · ")
    }

    private func chip(_ title: String, isOn: Binding<Bool>) -> some View {
        Button { isOn.wrappedValue.toggle() } label: {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .padding(.horizontal, Theme.Spacing.m)
                .padding(.vertical, Theme.Spacing.s)
                .foregroundStyle(isOn.wrappedValue ? Color.white : Color.primary)
                .background(isOn.wrappedValue ? Color.accentColor : Color.appTertiaryBackground, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn.wrappedValue ? .isSelected : [])
    }

    private func row(_ exercise: Exercise) -> some View {
        choiceRow(exercise.name,
                  detail: (exercise.primaryGroups.map(\.label) + [exercise.equipment.label.lowercased()]).joined(separator: " · "),
                  selected: selection?.id == exercise.id) {
            selection = exercise
            customName = nil
        }
    }

    private func customRow(_ name: String) -> some View {
        choiceRow("Use “\(name)”", detail: "Custom exercise · no muscle groups", selected: customName == name) {
            selection = nil
            customName = name
            weightKg = nil
        }
    }

    private func choiceRow(_ title: String, detail: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.m) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(detail).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "checkmark")
                    .foregroundStyle(Color.accentColor)
                    .opacity(selected ? 1 : 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// "Carries over: 3 sets · rest 0:45" — reps and load have their own rows.
    private var carriesOver: String {
        "Carries over: " + (["\(remaining.count) set\(remaining.count == 1 ? "" : "s")"] + [LiveFormat.rest(remaining.first?.rest)].compactMap { $0 })
            .joined(separator: " · ")
    }

    private func swap() {
        guard let name = selection?.name ?? customName else { return }
        LiveStrengthController.shared.update { s, _ in
            s.swap(unit: target.unit, replacing: target.set, with: selection?.id, name: name,
                   reps: reps, seconds: seconds, weightKg: weightKg)
        }
        dismiss()
    }
}
