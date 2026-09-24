import SwiftUI

// MARK: - Step editor
//
// Edits one `StepDraft` in place via binding — a leaf's type/extent/target, or a
// repeat block's count + child steps (child editors recurse with `allowRepeat`
// false, so repeats aren't nested — matching the display layer and the Garmin
// builder). All values edit the raw stored units; only durations and pace show
// as "m:ss" text (an exact, display-only conversion).

struct StepEditorView: View {
    @Binding var step: StepDraft
    let sport: EditorSport
    /// False inside a repeat block: child steps can't be repeats themselves.
    let allowRepeat: Bool

    @State private var showingExercisePicker = false

    var body: some View {
        Form {
            if step.isExercise {
                exerciseSection
                prescriptionSection
            } else if step.isRepeat {
                repeatSection
                childrenSection
            } else if sport == .strength {
                // A strength plan's only leaf is a rest between exercises.
                Section("Rest") {
                    mmssField("Duration", seconds: $step.durationSeconds)
                }
            } else {
                stepSection
                targetSection
            }
        }
        .formStyle(.grouped)
        .navigationTitle(step.isExercise ? "Exercise" : step.isRepeat ? "Repeat" : sport == .strength ? "Rest" : "Step")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .exercisePicker(
            isPresented: $showingExercisePicker,
            onSelectLibrary: { exercise in
                step.exerciseId = exercise.id
                step.exerciseName = exercise.name
                step.exerciseIsTimeBased = exercise.isTimeBased
                // Start from the weight this athlete last prescribed for it; nil
                // stays bodyweight rather than inventing a load.
                step.exerciseWeightKg = TrainingDataStore.shared.lastPlannedWeightKg(exerciseId: exercise.id)
            },
            onSelectCustom: { name in
                step.exerciseId = nil
                step.exerciseName = name
                step.exerciseIsTimeBased = false
            }
        )
    }

    /// What the athlete prescribed for this exercise last time — shown beside the
    /// weight field so a working weight is a memory, never a guess or a max test.
    private var lastPlannedWeightKg: Double? {
        step.exerciseId.flatMap { TrainingDataStore.shared.lastPlannedWeightKg(exerciseId: $0) }
    }

    // MARK: Exercise (strength only)

    private var exerciseSection: some View {
        Section("Exercise") {
            Button {
                showingExercisePicker = true
            } label: {
                HStack {
                    Text("Exercise").foregroundStyle(.primary)
                    Spacer()
                    Text(step.exerciseName.isEmpty ? "Select" : step.exerciseName)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
        }
    }

    private var prescriptionSection: some View {
        Section {
            Stepper("Sets: \(step.exerciseSets)", value: $step.exerciseSets, in: 1...20)
            if step.exerciseIsTimeBased {
                mmssField("Duration per set", seconds: $step.exerciseSetSeconds)
            } else {
                Stepper("Reps: \(step.exerciseReps)", value: $step.exerciseReps, in: 1...100)
            }
            Toggle("Bodyweight", isOn: bodyweight)
            if step.exerciseWeightKg != nil {
                numberField("Weight (kg)", value: $step.exerciseWeightKg, format: .number)
            }
            if let last = lastPlannedWeightKg {
                Text("Last planned: \(last.formatted(.number.precision(.fractionLength(0...1)))) kg")
                    .font(.caption).foregroundStyle(.secondary)
            }
            mmssField("Rest between sets", seconds: $step.exerciseRestSeconds)
        } header: {
            Text("Prescription")
        } footer: {
            Text("Applies to every set.")
        }
    }

    /// Nil `exerciseWeightKg` is bodyweight; toggling on picks a starting
    /// weight the athlete then edits.
    private var bodyweight: Binding<Bool> {
        Binding(get: { step.exerciseWeightKg == nil },
                set: { step.exerciseWeightKg = $0 ? nil : (step.exerciseWeightKg ?? 20) })
    }

    // MARK: Leaf

    private var stepSection: some View {
        Section("Step") {
            Picker("Type", selection: $step.kind) {
                ForEach(StepKind.allCases) { Text($0.label).tag($0) }
            }
            Picker("Ends by", selection: $step.end) {
                ForEach(StepEnd.allCases) { Text($0.label).tag($0) }
            }
            switch step.end {
            case .time, .fixedRest:
                mmssField("Duration", seconds: $step.durationSeconds)
            case .distance:
                numberField("Distance (m)", value: stepDistance, format: .number, prompt: "")
            case .lapButton:
                EmptyView()
            }
            if sport == .swimming {
                Picker("Stroke", selection: $step.stroke) {
                    Text("Default").tag(SwimStroke?.none)
                    ForEach(SwimStroke.allCases) { Text($0.label).tag(SwimStroke?.some($0)) }
                }
            }
        }
    }

    private var targetSection: some View {
        Section {
            Picker("Target", selection: $step.targetType) {
                ForEach(StepTargetType.allCases) { Text($0.label).tag($0) }
            }
            switch step.targetType {
            case .noTarget:
                EmptyView()
            case .pace:
                let unit = sport == .swimming ? "/100m" : "/km"
                mmssField("Fast (m:ss \(unit))", seconds: $step.targetLow)
                mmssField("Slow (m:ss \(unit))", seconds: $step.targetHigh)
            case .heartRate:
                numberField("Low (bpm)", value: $step.targetLow, format: .number)
                numberField("High (bpm)", value: $step.targetHigh, format: .number)
            case .power:
                numberField("Low (W)", value: $step.targetLow, format: .number)
                numberField("High (W)", value: $step.targetHigh, format: .number)
            case .speed:
                numberField("Low (km/h)", value: $step.targetLow, format: .number)
                numberField("High (km/h)", value: $step.targetHigh, format: .number)
            case .cadence:
                let unit = sport == .cycling ? "rpm" : "spm"
                numberField("Low (\(unit))", value: $step.targetLow, format: .number)
                numberField("High (\(unit))", value: $step.targetHigh, format: .number)
            }
        } header: {
            Text("Intensity target")
        } footer: {
            if step.targetType != .noTarget {
                Text("A single value is auto-widened into a band on save.")
            }
        }
    }

    /// `distanceMeters` is non-optional (the end condition guarantees a value);
    /// clearing the field just keeps the previous distance.
    private var stepDistance: Binding<Double?> {
        Binding(get: { step.distanceMeters },
                set: { if let v = $0, v > 0 { step.distanceMeters = v } })
    }

    // MARK: Repeat block

    private var repeatSection: some View {
        Section("Repeat") {
            Stepper("Repetitions: \(step.repeatCount)", value: $step.repeatCount, in: 2...50)
            if sport == .strength {
                // A circuit's children are exercises, not the interval/rest
                // step pairs an endurance repeat block uses — there's no rest
                // *step* to skip, so rest between rounds is its own field.
                mmssField("Rest between rounds", seconds: $step.restBetweenRoundsSeconds)
            } else {
                Toggle("Skip last rest", isOn: $step.skipLastRest)
            }
        }
    }

    private var childrenSection: some View {
        Section("Steps") {
            ForEach($step.children) { $child in
                NavigationLink {
                    StepEditorView(step: $child, sport: sport, allowRepeat: false)
                } label: {
                    Text(child.summary(sport: sport)).lineLimit(2)
                }
                // macOS has no swipe-to-delete or drag-to-reorder; a right-click
                // here edits without ever touching navigation/dismiss state —
                // unlike a delete button inside the pushed detail view, which
                // crashed AppKit's window layout on open (see git history).
                .contextMenu {
                    reorderButtons($step.children, id: child.id)
                    Button("Delete", role: .destructive) {
                        step.children.removeAll { $0.id == child.id }
                    }
                }
            }
            .onDelete { step.children.remove(atOffsets: $0) }
            .onMove { step.children.move(fromOffsets: $0, toOffset: $1) }
            if sport == .strength {
                Menu("Add") {
                    Button("Exercise") { step.children.append(StepDraft.exercise()) }
                    Button("Rest") { step.children.append(StepDraft.exerciseRest()) }
                }
            } else {
                Button("Add step") { step.children.append(StepDraft(kind: .interval)) }
            }
        }
    }
}
