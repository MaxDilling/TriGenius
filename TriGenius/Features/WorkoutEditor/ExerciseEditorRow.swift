import SwiftUI

// MARK: - Exercise row
//
// One planned exercise, edited in place: collapsed, its figure, name and
// prescription at a glance; expanded, sets, reps (or a hold's time) and weight
// side by side, then its rests. On "Auto weight" the weight is the one its last
// sessions call for (`StrengthProgression`), set for good 4 days before the
// session (`PlanResolution`) — until then the field shows today's value. The
// workout editor and the live "add exercise" sheet both list exercises as these rows.
//
// The expanded part is the disclosure's one child — a form makes each child a
// row of its own, separated from the next — with no separator above it, so it
// reads as part of the exercise.

struct ExerciseEditorRow: View {
    @Binding var step: StepDraft
    @Binding var isExpanded: Bool
    /// False for a circuit member: members follow each other directly.
    let pausesAfter: Bool
    let onReplace: () -> Void

    @State private var lastNote: String?
    /// Today's auto weight; nil when off or the exercise was never recorded.
    @State private var autoKg: Double?
    @State private var showsAutoInfo = false

    var body: some View {
        DisclosureGroup(isExpanded: expansion) {
            details
                .listRowSeparator(.hidden, edges: .top)
                .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
                #if os(iOS)
                // Tucked up under the header; the sides restate iOS's row inset,
                // which `EdgeInsets` can't leave out.
                .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: Theme.Spacing.m, trailing: 20))
                #endif
        } label: {
            header
                .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
        }
    }

    private var header: some View {
        HStack(spacing: Theme.Spacing.m) {
            ExerciseThumbnail(exercise: step.exerciseId.flatMap(ExerciseLibrary.find(id:)))
            VStack(alignment: .leading, spacing: 2) {
                Text(step.exerciseName)
                Text(step.prescription).font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer(minLength: 0)
            if isExpanded {
                Button("Replace Exercise", systemImage: "arrow.left.arrow.right", action: onReplace)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .padding(.trailing, Theme.Spacing.s)
            }
        }
        #if os(macOS)
        // iOS makes the whole label the toggle; the Mac only its chevron.
        .contentShape(.rect)
        .onTapGesture { expansion.wrappedValue.toggle() }
        #endif
    }

    /// The Mac's disclosure triangle sets the binding without an animation;
    /// iOS lists animate the disclosure themselves.
    private var expansion: Binding<Bool> {
        #if os(macOS)
        $isExpanded.animation()
        #else
        $isExpanded
        #endif
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            HStack(spacing: Theme.Spacing.s) {
                PrescriptionField("Sets") { TextField("", value: clamped(\.exerciseSets, 1...20), format: .number).numberPad() }
                if step.exerciseSets > 1 {
                    RestField(rest: $step.setRest)
                }
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
                        .disabled(autoKg != nil)
                }
            }
            if step.canAutoLoad {
                Toggle(isOn: $step.autoLoad) {
                    HStack(spacing: Theme.Spacing.xs) {
                        Text("Auto weight")
                        Button("About Auto Weight", systemImage: "info.circle") { showsAutoInfo = true }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .popover(isPresented: $showsAutoInfo) {
                                Text(autoInfo)
                                    .font(.callout)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(width: 280)
                                    .padding()
                                    .presentationCompactAdaptation(.popover)
                            }
                    }
                }
                .padding(.top, Theme.Spacing.xs)
            }
            if pausesAfter {
                RestMenu(title: "Rest after exercise", rest: $step.pauseAfter, allowsNone: true)
            }
            if let lastNote {
                Text(lastNote).font(.caption).foregroundStyle(.secondary)
            }
        }
        // Loaded once the row opens, not for every collapsed row.
        .task(id: step.exerciseId) { lastNote = Self.lastNote(step.exerciseId) }
        .task(id: AutoInput(step)) {
            autoKg = step.autoLoad ? TrainingDataStore.shared.autoWeightKg(step.dict(swim: false)) : nil
            if let autoKg { step.exerciseWeightKg = autoKg }
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

    private var autoInfo: String {
        "The weight follows your last two sessions of this exercise — the reps you did against the target and how each set felt — and is set for good 4 days before the session."
            + (step.autoLoad && autoKg == nil ? " Until you have recorded it, the weight you enter is used." : "")
    }

    /// What today's auto weight depends on.
    private struct AutoInput: Hashable {
        let exerciseId: String?, auto: Bool, sets: Int, reps: Int
        init(_ step: StepDraft) {
            (exerciseId, auto, sets, reps) = (step.exerciseId, step.autoLoad, step.exerciseSets, step.exerciseReps)
        }
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
        var parts = ["\(exerciseSets) × \(extent)", LiveFormat.load(exerciseWeightKg) + (autoLoad ? " (auto)" : "")]
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
        Picker(title, selection: $rest) { Self.choices(rest, allowsLap: allowsLap, allowsNone: allowsNone) }
    }

    @ViewBuilder
    static func choices(_ rest: StrengthSets.Rest?, allowsLap: Bool, allowsNone: Bool) -> some View {
        if allowsLap { Text("Until lap").tag(StrengthSets.Rest?.some(.lapButton)) }
        ForEach(times(rest), id: \.self) { Text(ExerciseSetsCard.time($0)).tag(StrengthSets.Rest?.some(.timed(seconds: $0))) }
        if allowsNone { Text("None").tag(StrengthSets.Rest?.none) }
    }

    /// The presets, plus the current time when it is none of them.
    private static func times(_ rest: StrengthSets.Rest?) -> [Double] {
        guard case .timed(let seconds) = rest, !presets.contains(seconds) else { return presets }
        return (presets + [seconds]).sorted()
    }
}

/// The rest between sets as a prescription box beside sets, reps and kg —
/// its value, tapped for `RestMenu`'s choices.
struct RestField: View {
    @Binding var rest: StrengthSets.Rest?

    var body: some View {
        PrescriptionField("Rest") {
            Menu {
                Picker("Rest", selection: $rest) { RestMenu.choices(rest, allowsLap: true, allowsNone: false) }
                    .pickerStyle(.inline)
            } label: {
                Text(value).frame(maxWidth: .infinity)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
        }
    }

    private var value: String {
        switch rest {
        case .timed(let seconds): ExerciseSetsCard.time(seconds)
        case .lapButton: "Lap"
        case nil: "–"
        }
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
