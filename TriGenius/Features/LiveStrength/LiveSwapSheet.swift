import SwiftUI

// MARK: - Swap an exercise for today
//
// Replaces every set still to do of one exercise in one unit with another
// library exercise — what the athlete's `StrengthProfile` allows first — or a
// custom name typed into the search, for this session only; rows look like the
// exercise picker's (`ExerciseChoiceRow`). Candidates share
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
        isHold = target.set.isHold
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
                if !trimmedQuery.isEmpty,
                   !ExerciseLibrary.all.contains(where: { $0.name.caseInsensitiveCompare(trimmedQuery) == .orderedSame }) {
                    Section { customRow(trimmedQuery) }
                        .listSectionSeparator(.hidden)
                }
                ForEach(sections, id: \.rank) { section in
                    Section(Self.sectionTitles[section.rank] ?? "") {
                        ForEach(section.exercises) { row($0) }
                    }
                    .listSectionSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .onChange(of: selection?.id) {
                weightKg = selection.flatMap { TrainingDataStore.shared.startingWeightKg(for: $0) }
            }
            .exerciseSearch($query, prompt: "Search exercises")
            .navigationTitle("Swap exercise")
            .pickerTitleDisplay()
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

    /// The exercise, what carries over, then reps (or a hold's time) and load
    /// side by side, then the filters — kept short, so the list starts high.
    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(target.set.title).font(.headline)
            Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        HStack(spacing: Theme.Spacing.s) {
            if isHold {
                PrescriptionField("Time") {
                    TextField("", text: Binding(get: { MMSS.format(Int((seconds ?? remaining.first?.seconds ?? 0).rounded())) },
                                                set: { if let s = MMSS.parse($0), s > 0 { seconds = Double(s) } }))
                }
            } else {
                PrescriptionField("Reps") {
                    TextField("", value: Binding(get: { reps ?? remaining.first?.reps ?? 0 }, set: { reps = min(max($0, 1), 100) }),
                              format: .number)
                        .numberPad()
                }
            }
            PrescriptionField("kg") {
                TextField("", value: $weightKg, format: .number, prompt: Text("BW")).decimalPad()
            }
            .disabled(selection == nil && customName == nil)
        }
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
        ExerciseChoiceRow(choice: .library(exercise),
                          detail: (exercise.primaryGroups.map(\.label) + [exercise.equipment.label.lowercased()]).joined(separator: " · "),
                          selected: selection?.id == exercise.id) {
            selection = exercise
            customName = nil
        }
    }

    private func customRow(_ name: String) -> some View {
        ExerciseChoiceRow(choice: .custom(name), detail: "Custom exercise · no muscle groups", selected: customName == name) {
            selection = nil
            customName = name
            weightKg = nil
        }
    }

    /// "Hamstrings, low back · 3 sets · rest 0:45" — its primary groups, then
    /// what carries over to the replacement.
    private var subtitle: String {
        let groups = replaced.map { $0.primaryGroups.map(\.label).joined(separator: ", ") }
        let sets = "\(remaining.count) set\(remaining.count == 1 ? "" : "s")"
        return ([groups, sets, LiveFormat.rest(remaining.first?.rest)].compactMap { $0 }).joined(separator: " · ")
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
