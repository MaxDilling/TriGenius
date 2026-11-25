import SwiftUI

// MARK: - Exercise row
//
// One planned exercise, edited in place: collapsed, its figure, name and
// prescription at a glance; expanded, sets, reps (or a hold's time) and weight
// side by side, then its rests. The workout editor and the live "add exercise"
// sheet both list exercises as these rows.

struct ExerciseEditorRow: View {
    @Binding var step: StepDraft
    @Binding var isExpanded: Bool
    /// False for a circuit member: members follow each other directly.
    let pausesAfter: Bool
    let onReplace: () -> Void

    @State private var lastNote: String?

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            HStack(spacing: Theme.Spacing.s) {
                PrescriptionField("Sets") { TextField("", value: clamped(\.exerciseSets, 1...20), format: .number).numberPad() }
                if step.exerciseIsTimeBased {
                    PrescriptionField("Time") {
                        TextField("", text: Binding(get: { MMSS.format(step.exerciseSetSeconds) },
                                                    set: { if let s = MMSS.parse($0), s > 0 { step.exerciseSetSeconds = s } }),
                                  prompt: Text("m:ss"))
                    }
                } else {
                    PrescriptionField("Reps") { TextField("", value: clamped(\.exerciseReps, 1...100), format: .number).numberPad() }
                }
                PrescriptionField("kg") {
                    TextField("", value: $step.exerciseWeightKg, format: .number, prompt: Text("BW")).decimalPad()
                }
            }
            // Loaded once the row opens, not for every collapsed row.
            .task(id: step.exerciseId) { lastNote = Self.lastNote(step.exerciseId) }
            if step.exerciseSets > 1 {
                RestMenu(title: "Rest between sets", rest: $step.setRest)
            }
            if pausesAfter {
                RestMenu(title: "Rest after exercise", rest: $step.pauseAfter, allowsNone: true)
            }
            if let lastNote {
                Text(lastNote).font(.caption).foregroundStyle(.secondary)
            }
            Button("Replace Exercise", systemImage: "arrow.triangle.2.circlepath", action: onReplace)
                .buttonStyle(.borderless)
        } label: {
            HStack(spacing: Theme.Spacing.m) {
                ExerciseThumbnail(exercise: step.exerciseId.flatMap(ExerciseLibrary.find(id:)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(step.exerciseName)
                    Text(step.prescription).font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            #if os(macOS)
            // iOS makes the whole label the toggle; the Mac only its chevron.
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
            .onTapGesture { withAnimation { isExpanded.toggle() } }
            #endif
        }
    }

    /// What the athlete lifted on this exercise last time, else what they last
    /// prescribed — so a working weight is a memory, never a guess or a max test.
    private static func lastNote(_ exerciseId: String?) -> String? {
        guard let exercise = exerciseId.flatMap(ExerciseLibrary.find(id:)) else { return nil }
        let lifted = TrainingDataStore.shared.lastLiftedSets(for: exercise)
        if !lifted.isEmpty { return "Last lifted: \(ExerciseSetsCard.volume(lifted))" }
        return TrainingDataStore.shared.lastPlannedWeightKg(exerciseId: exercise.id)
            .map { "Last planned: \($0.formatted(.number.precision(.fractionLength(0...1)))) kg" }
    }

    private func clamped(_ key: WritableKeyPath<StepDraft, Int>, _ range: ClosedRange<Int>) -> Binding<Int> {
        Binding(get: { step[keyPath: key] }, set: { step[keyPath: key] = min(max($0, range.lowerBound), range.upperBound) })
    }
}

/// A titled value box — sets, reps, kg — laid side by side with its siblings.
struct PrescriptionField<Input: View>: View {
    let title: String
    let input: Input

    init(_ title: String, @ViewBuilder input: () -> Input) {
        self.title = title
        self.input = input()
    }

    var body: some View {
        VStack(spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            input
                .textFieldStyle(.plain)
                .multilineTextAlignment(.center)
                .font(.title3.monospacedDigit())
                .labelsHidden()
        }
        .padding(.vertical, Theme.Spacing.s)
        .frame(maxWidth: .infinity)
        .background(Color.appTertiaryBackground, in: .rect(cornerRadius: Theme.Radius.s))
    }
}

extension StepDraft {
    /// "3 × 10 · 60 kg · rest 1:30" — sets × reps (or hold time), the load, and
    /// the rest between sets.
    var prescription: String {
        let extent = exerciseIsTimeBased ? MMSS.format(exerciseSetSeconds) : "\(exerciseReps)"
        var parts = ["\(exerciseSets) × \(extent)", LiveFormat.load(exerciseWeightKg)]
        if exerciseSets > 1, let setRest { parts.append(ExerciseSetsCard.restLabel(setRest).lowercased()) }
        return parts.joined(separator: " · ")
    }
}

/// A rest as one menu: until lap, a preset time, or — where it may — none.
struct RestMenu: View {
    let title: String
    @Binding var rest: StrengthSets.Rest?
    var allowsLap = true
    var allowsNone = false

    private static let presets: [Double] = [30, 45, 60, 90, 120, 150, 180, 240, 300]

    var body: some View {
        Picker(title, selection: $rest) {
            if allowsLap { Text("Until lap").tag(StrengthSets.Rest?.some(.lapButton)) }
            ForEach(times, id: \.self) { Text(ExerciseSetsCard.time($0)).tag(StrengthSets.Rest?.some(.timed(seconds: $0))) }
            if allowsNone { Text("None").tag(StrengthSets.Rest?.none) }
        }
    }

    /// The presets, plus the current time when it is none of them.
    private var times: [Double] {
        guard case .timed(let seconds) = rest, !Self.presets.contains(seconds) else { return Self.presets }
        return (Self.presets + [seconds]).sorted()
    }
}

/// An exercise's animation in a fixed slot, so the names beside it line up —
/// a dumbbell where the exercise has no pose (or is a custom one).
struct ExerciseThumbnail: View {
    let exercise: Exercise?

    var body: some View {
        Color.clear
            .frame(width: 48, height: 36)
            .overlay {
                if let animation = exercise.flatMap(ExerciseAnimation.init(exercise:)) {
                    animation
                } else {
                    Image(systemName: "dumbbell").foregroundStyle(.secondary)
                }
            }
    }
}

extension View {
    /// The iOS keyboard for whole numbers; nothing on the Mac.
    func numberPad() -> some View {
        #if os(iOS)
        keyboardType(.numberPad)
        #else
        self
        #endif
    }

    /// The iOS keyboard for decimals; nothing on the Mac.
    func decimalPad() -> some View {
        #if os(iOS)
        keyboardType(.decimalPad)
        #else
        self
        #endif
    }
}
