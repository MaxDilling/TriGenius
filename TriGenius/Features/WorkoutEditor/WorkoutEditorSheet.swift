import SwiftUI

// MARK: - Workout editor sheet
//
// The manual create/edit form for planned workouts, reached from the calendar's
// "+" and the planned-workout detail's Edit. A full-state form over `WorkoutDraft`;
// saving routes through `DataSyncCoordinator`'s shared plan CRUD — the exact write
// path the coach's scheduling tools use.

/// What the sheet edits: a fresh plan on a date, or an existing record.
enum WorkoutEditorContext: Identifiable {
    case create(date: Date)
    case edit(WorkoutRecord)

    var id: String {
        switch self {
        case .create(let date): return "create-\(date.timeIntervalSinceReferenceDate)"
        case .edit(let record): return "edit-\(record.id)"
        }
    }
}

struct WorkoutEditorSheet: View {
    @State private var draft: WorkoutDraft
    /// Plan id when editing; nil when creating.
    private let editingId: String?
    private let originalDay: Date?
    private let originalStartMinute: Int?
    @State private var saving = false
    @State private var validationError: String?
    @Environment(\.dismiss) private var dismiss

    @MainActor
    init(context: WorkoutEditorContext) {
        switch context {
        case .create(let date):
            _draft = State(initialValue: WorkoutDraft(date: date))
            editingId = nil
            originalDay = nil
            originalStartMinute = nil
        case .edit(let record):
            _draft = State(initialValue: WorkoutDraft(record: record))
            editingId = record.id
            originalDay = Calendar.current.startOfDay(for: record.date)
            originalStartMinute = record.startMinute
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                basicsSection
                stepsSection
            }
            .formStyle(.grouped)
            .navigationTitle(editingId == nil ? "New Workout" : "Edit \(draft.sport.label) Workout")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(saving)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 560)
        #endif
        .alert("Can't Save Workout", isPresented: Binding(get: { validationError != nil }, set: { if !$0 { validationError = nil } })) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(validationError ?? "")
        }
    }

    // MARK: Basics

    private var basicsSection: some View {
        Section("Workout") {
            TextField("Name", text: $draft.name, prompt: Text("auto"))
            // A plan's sport is fixed once it exists — the title names it.
            if editingId == nil {
                Picker("Sport", selection: $draft.sport) {
                    ForEach(EditorSport.allCases) { sport in
                        Label(sport.label, systemImage: sport.family.icon).tag(sport)
                    }
                }
            }
            DatePicker("Date", selection: $draft.date, displayedComponents: .date)
            LabeledContent("Time") {
                HStack {
                    if draft.startMinute != nil {
                        Button("Clear") { draft.startMinute = nil }.buttonStyle(.borderless)
                    }
                    DatePicker("Time", selection: startTime, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .opacity(draft.startMinute == nil ? 0.5 : 1)
                }
            }
            numberField("Duration (min)", value: $draft.durationMinutes, format: .number)
            // Strength is the one sport with no meaningful distance — yoga,
            // cardio and other share strength's SportFamily.other bucket but
            // can still carry one (e.g. a hike logged as "other").
            if draft.sport != .strength {
                numberField(draft.sport == .swimming ? "Distance (m)" : "Distance (km)", value: distance, format: .number)
            }
            if draft.sport == .swimming {
                numberField("Pool length (m)", value: $draft.poolLength, format: .number, prompt: "50")
            }
            TextField("Notes", text: $draft.notes, axis: .vertical)
        }
    }

    private var startTime: Binding<Date> {
        Binding(
            get: {
                let m = draft.startMinute ?? 0
                return Calendar.current.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: draft.date) ?? draft.date
            },
            set: {
                let c = Calendar.current.dateComponents([.hour, .minute], from: $0)
                draft.startMinute = (c.hour ?? 0) * 60 + (c.minute ?? 0)
            }
        )
    }

    /// Distance is stored in meters; the field shows km for land sports, meters
    /// for swims (an exact ×1000, display-only).
    private var distance: Binding<Double?> {
        let isSwim = draft.sport == .swimming
        return Binding(
            get: { draft.distanceMeters.map { isSwim ? $0 : $0 / 1000 } },
            set: { draft.distanceMeters = $0.map { isSwim ? $0 : $0 * 1000 } }
        )
    }

    // MARK: Steps

    private var stepsSection: some View {
        Section {
            ForEach($draft.steps) { $step in
                NavigationLink {
                    StepEditorView(step: $step, sport: draft.sport, allowRepeat: true)
                } label: {
                    Text(step.summary(sport: draft.sport))
                        .lineLimit(2)
                }
                .reorderable(step.id, in: $draft.steps)
                // macOS has no swipe-to-delete; a right-click here deletes without
                // touching navigation/dismiss state — unlike a delete button inside
                // the pushed detail view, which crashed AppKit's window layout on
                // open (see git history).
                .contextMenu {
                    Button("Delete", role: .destructive) {
                        draft.steps.removeAll { $0.id == step.id }
                    }
                }
            }
            .onDelete { draft.steps.remove(atOffsets: $0) }
            addButtons {
                if draft.sport == .strength {
                    Button("Exercise", systemImage: "plus") { draft.steps.append(StepDraft.exercise()) }
                    Button("Circuit", systemImage: "plus") { draft.steps.append(StepDraft.exerciseCircuit()) }
                    Button("Rest", systemImage: "plus") { draft.steps.append(StepDraft.exerciseRest()) }
                } else {
                    Button("Step", systemImage: "plus") { draft.steps.append(StepDraft()) }
                    Button("Repeat block", systemImage: "plus") { draft.steps.append(StepDraft(isRepeat: true)) }
                }
            }
        } header: {
            Text("Steps")
        } footer: {
            Text(draft.sport == .strength
                 ? "Add each exercise with its sets, reps and weight, and rests between exercises. Leave empty for an unstructured, duration-only session."
                 : "Leave empty to auto-build a warm-up / main / cool-down structure from the duration or distance goal.")
        }
    }

    // MARK: Save

    /// Local write first (source of truth); a failed target push is non-fatal —
    /// `reconcileWriteTarget` re-pushes, same contract as drag-to-reschedule.
    private func save() async {
        saving = true
        let day = Calendar.current.startOfDay(for: draft.date)
        if let editingId {
            if case .rejected(let errors) = await DataSyncCoordinator.shared.updatePlan(id: editingId, workoutData: draft.workoutData()) {
                validationError = errors.joined(separator: "\n")
                saving = false
                return
            }
            if day != originalDay {
                _ = await DataSyncCoordinator.shared.movePlan(id: editingId, to: day)
            }
            if draft.startMinute != originalStartMinute {
                _ = TrainingDataStore.shared.setScheduledStartMinute(id: editingId, minute: draft.startMinute)
            }
        } else {
            if case .rejected(let errors) = await DataSyncCoordinator.shared.addPlan(workoutData: draft.workoutData(), date: day,
                                                         startMinute: draft.startMinute) {
                validationError = errors.joined(separator: "\n")
                saving = false
                return
            }
        }
        dismiss()
    }
}

// MARK: - Shared field helpers

/// An optional numeric form field, right-aligned like the ATP editor's.
/// `LabeledContent`, not a bare `TextField(label, …)`: macOS's `Form` splits
/// any labeled control into "label: value" automatically, but iOS/iPadOS
/// doesn't — there the title reads only as the field's own placeholder-ish
/// text, so once a value exists the leading label disappears. `LabeledContent`
/// renders the label consistently on both.
func numberField<F: ParseableFormatStyle>(_ label: String, value: Binding<F.FormatInput?>, format: F, prompt: String = "optional") -> some View where F.FormatOutput == String {
    LabeledContent(label) {
        TextField("", value: value, format: format, prompt: Text(prompt))
            .multilineTextAlignment(.trailing)
            #if os(iOS)
            .keyboardType(.decimalPad)
            #endif
    }
}

extension View {
    /// Drag this row onto another row of `items` to move it into that slot.
    /// Drag and drop, not `onMove`: macOS's grouped `Form` is not a `List`, so
    /// `onMove` never gets a drag there.
    func reorderable<Item: Identifiable>(_ id: UUID, in items: Binding<[Item]>) -> some View where Item.ID == UUID {
        draggable(id.uuidString)
            .dropDestination(for: String.self) { dropped, _ in
                let list = items.wrappedValue
                guard let movedId = dropped.first.flatMap(UUID.init(uuidString:)),
                      let from = list.firstIndex(where: { $0.id == movedId }),
                      let to = list.firstIndex(where: { $0.id == id }), from != to else { return }
                items.wrappedValue.move(fromOffsets: [from], toOffset: to > from ? to + 1 : to)
            }
    }
}

/// A form's add row: one borderless "+" button per kind, side by side.
func addButtons<Content: View>(@ViewBuilder _ buttons: () -> Content) -> some View {
    HStack(spacing: Theme.Spacing.l) {
        buttons()
    }
    .labelStyle(.titleAndIcon)
    .buttonStyle(.borderless)
}

/// An "m:ss" field over whole seconds (display-only conversion; the stored
/// value stays raw seconds). Unparseable input keeps the previous value.
func mmssField(_ label: String, seconds: Binding<Int>) -> some View {
    mmssTextField(label, text: Binding(
        get: { MMSS.format(seconds.wrappedValue) },
        set: { if let s = MMSS.parse($0) { seconds.wrappedValue = s } }
    ))
}

/// An optional "m:ss" field — a pace target, a set's time or rest. Unparseable
/// input clears it.
func mmssField(_ label: String, seconds: Binding<Double?>) -> some View {
    mmssTextField(label, text: Binding(
        get: { seconds.wrappedValue.map { MMSS.format(Int($0.rounded())) } ?? "" },
        set: { seconds.wrappedValue = MMSS.parse($0).map(Double.init) }
    ))
}

/// `LabeledContent` for the same reason as `numberField`.
private func mmssTextField(_ label: String, text: Binding<String>) -> some View {
    LabeledContent(label) {
        TextField("", text: text, prompt: Text("m:ss"))
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
            #if os(iOS)
            .keyboardType(.numbersAndPunctuation)
            #endif
    }
}

private enum MMSS {
    static func format(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    /// "m:ss" → seconds; a bare number reads as whole minutes.
    static func parse(_ text: String) -> Int? {
        let parts = text.split(separator: ":")
        if parts.count == 2, let m = Int(parts[0]), let s = Int(parts[1]), s < 60, m >= 0, s >= 0 {
            return m * 60 + s
        }
        if parts.count == 1, let m = Int(parts[0]), m >= 0 { return m * 60 }
        return nil
    }
}

extension StepDraft {
    /// One-line summary for list rows, e.g. "4× (Interval 400 m @ 1:45–1:55 /100m / Rest 30 s)".
    func summary(sport: EditorSport) -> String {
        if isExercise {
            let extent = exerciseIsTimeBased ? PlannedWorkoutFormat.duration(Double(exerciseSetSeconds)) : "\(exerciseReps) reps"
            let load = exerciseWeightKg.map { " @ \($0.truncatingRemainder(dividingBy: 1) == 0 ? String(Int($0)) : String(format: "%.1f", $0)) kg" } ?? " (bodyweight)"
            return "\(exerciseName) \(exerciseSets)×\(extent)\(load)"
        }
        if isRepeat {
            let inner = children.map { $0.summary(sport: sport) }.joined(separator: " / ")
            return "\(repeatCount)× (\(inner))"
        }
        var parts = [kind.label]
        switch end {
        case .distance: parts.append(PlannedWorkoutFormat.distance(distanceMeters))
        case .time, .fixedRest: parts.append(PlannedWorkoutFormat.duration(Double(durationSeconds)))
        case .lapButton: parts.append("lap button")
        }
        if let target = targetText(sport: sport) { parts.append("@ \(target)") }
        return parts.joined(separator: " ")
    }

    /// Formatted target range in the type's display unit (raw values are stored).
    func targetText(sport: EditorSport) -> String? {
        switch targetType {
        case .noTarget: return nil
        case .power: return PlannedWorkoutFormat.range(targetLow, targetHigh, unit: "W")
        case .heartRate: return PlannedWorkoutFormat.range(targetLow, targetHigh, unit: "bpm")
        case .pace: return PlannedWorkoutFormat.paceRange(targetLow, targetHigh, swim: sport == .swimming)
        case .speed: return PlannedWorkoutFormat.speedRange(targetLow, targetHigh)
        case .cadence: return PlannedWorkoutFormat.range(targetLow, targetHigh, unit: sport == .cycling ? "rpm" : "spm")
        }
    }
}
