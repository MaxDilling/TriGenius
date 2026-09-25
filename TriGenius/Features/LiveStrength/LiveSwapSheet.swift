import SwiftUI

// MARK: - Swap an exercise for today
//
// Replaces every set still to do of one exercise in one unit with another
// library exercise the athlete's `StrengthProfile` allows — for this session
// only. Candidates share the set's kind (reps or a hold), so the prescription
// carries over unchanged; the weight starts from what the athlete lifted or
// planned for the new exercise; reps (or a hold's time) and weight can be
// adjusted before swapping. Ranked by the tissue groups they share with the
// replaced one: the same primary groups, then any overlap.

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
    @State private var weightKg: Double?
    /// Nil keeps each set's own.
    @State private var reps: Int?
    @State private var seconds: Double?

    private let replaced: Exercise?
    private let isHold: Bool
    /// The sets the swap replaces.
    private let remaining: [StrengthSets.SetRow]

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

    private var candidates: [(exercise: Exercise, rank: Int)] {
        let profile = StrengthProfile.stored
        let ranked: [(exercise: Exercise, rank: Int)] = ExerciseLibrary.all
            .filter { profile.allows($0) && matches($0) }
            .map { ($0, rank($0)) }
        return ranked
            .filter { !sameMuscles || $0.rank > 0 }
            .sorted { $0.rank != $1.rank ? $0.rank > $1.rank : $0.exercise.name < $1.exercise.name }
    }

    private func matches(_ exercise: Exercise) -> Bool {
        guard exercise.id != replaced?.id, exercise.isTimeBased == isHold else { return false }
        if let equipment, exercise.equipment != equipment { return false }
        return query.isEmpty || exercise.name.localizedCaseInsensitiveContains(query)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(candidates, id: \.exercise.id) { candidate in
                        row(candidate.exercise, rank: candidate.rank)
                    }
                    if candidates.isEmpty {
                        Text("No exercise matches.").foregroundStyle(.secondary)
                    }
                } header: {
                    header
                }
                Section("Carries over") {
                    Text(carriesOver).font(.headline).monospacedDigit()
                    if isHold {
                        let shown = seconds ?? remaining.first?.seconds ?? 0
                        Stepper("Time: \(ExerciseSetsCard.time(shown))",
                                value: Binding(get: { shown }, set: { seconds = $0 }), in: 5...600, step: 5)
                    } else {
                        let shown = reps ?? remaining.first?.reps ?? 0
                        Stepper("Reps: \(shown)", value: Binding(get: { shown }, set: { reps = $0 }), in: 1...100)
                    }
                    if selection != nil {
                        Stepper("Load: \(LiveFormat.load(weightKg))",
                                value: Binding(get: { weightKg ?? 0 }, set: { weightKg = $0 > 0 ? $0 : nil }),
                                in: 0...500, step: 2.5)
                    }
                }
            }
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
                    Button("Swap", role: .confirm) { swap() }.disabled(selection == nil)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 560)
        #endif
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text("Replacing").font(.subheadline).foregroundStyle(.secondary)
                Text(target.set.title).font(.title2.bold()).foregroundStyle(.primary)
                if let groups = replaced.map(groupsLine) {
                    Text(groups).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: Theme.Spacing.s) {
                chip("Same muscles", isOn: $sameMuscles).disabled(replaced == nil)
                chip("No equipment", isOn: equipmentFilter(.bodyweight))
                chip("Machines", isOn: equipmentFilter(.machine))
            }
            Text("Recommended")
        }
        .textCase(nil)
        .padding(.bottom, Theme.Spacing.xs)
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
                .padding(.horizontal, Theme.Spacing.m)
                .padding(.vertical, Theme.Spacing.s)
                .foregroundStyle(isOn.wrappedValue ? Color.white : Color.primary)
                .background(isOn.wrappedValue ? Color.accentColor : Color.appTertiaryBackground, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn.wrappedValue ? .isSelected : [])
    }

    private func row(_ exercise: Exercise, rank: Int) -> some View {
        Button { selection = exercise } label: {
            HStack(spacing: Theme.Spacing.m) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(exercise.name).font(.headline)
                    Text((exercise.primaryGroups.map(\.label) + [exercise.equipment.label.lowercased()]).joined(separator: " · "))
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                if rank > 0 {
                    let color = rank == 2 ? Theme.Palette.success : Theme.Palette.info
                    Text(rank == 2 ? "Same muscles" : "Similar")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(color)
                        .padding(.horizontal, Theme.Spacing.s)
                        .padding(.vertical, Theme.Spacing.xs)
                        .background(color.opacity(0.18), in: Capsule())
                }
                Image(systemName: "checkmark")
                    .foregroundStyle(Color.accentColor)
                    .opacity(selection?.id == exercise.id ? 1 : 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// "3 sets · rest 0:45" — reps and load have their own rows.
    private var carriesOver: String {
        (["\(remaining.count) set\(remaining.count == 1 ? "" : "s")"] + [LiveFormat.rest(remaining.first?.rest)].compactMap { $0 })
            .joined(separator: " · ")
    }

    private func swap() {
        guard let selection else { return }
        LiveStrengthController.shared.update { s, _ in
            s.swap(unit: target.unit, replacing: target.set, with: selection.id, name: selection.name,
                   reps: reps, seconds: seconds, weightKg: weightKg)
        }
        dismiss()
    }
}
