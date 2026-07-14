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
            .navigationTitle(editingId == nil ? "New Workout" : "Edit Workout")
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
            Picker("Sport", selection: $draft.sport) {
                ForEach(EditorSport.allCases) { sport in
                    Label(sport.label, systemImage: sport.family.icon).tag(sport)
                }
            }
            DatePicker("Date", selection: $draft.date, displayedComponents: .date)
            Toggle("Set start time", isOn: hasStartTime)
            if draft.startMinute != nil {
                DatePicker("Start time", selection: startTime, displayedComponents: .hourAndMinute)
            }
            numberField("Duration (min)", value: $draft.durationMinutes, format: .number)
            numberField(draft.sport == .swimming ? "Distance (m)" : "Distance (km)", value: distance, format: .number)
            if draft.sport == .swimming {
                numberField("Pool length (m)", value: $draft.poolLength, format: .number, prompt: "50")
            }
            TextField("Notes", text: $draft.notes, axis: .vertical)
        }
    }

    private var hasStartTime: Binding<Bool> {
        Binding(get: { draft.startMinute != nil },
                set: { draft.startMinute = $0 ? (draft.startMinute ?? 8 * 60) : nil })
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
            }
            .onDelete { draft.steps.remove(atOffsets: $0) }
            .onMove { draft.steps.move(fromOffsets: $0, toOffset: $1) }
            Menu("Add") {
                Button("Step") { draft.steps.append(StepDraft()) }
                Button("Repeat block") { draft.steps.append(StepDraft(isRepeat: true)) }
            }
        } header: {
            Text("Steps")
        } footer: {
            Text("Leave empty to auto-build a warm-up / main / cool-down structure from the duration or distance goal.")
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
func numberField<F: ParseableFormatStyle>(_ label: String, value: Binding<F.FormatInput?>, format: F, prompt: String = "optional") -> some View where F.FormatOutput == String {
    TextField(label, value: value, format: format, prompt: Text(prompt))
        .multilineTextAlignment(.trailing)
        #if os(iOS)
        .keyboardType(.decimalPad)
        #endif
}

extension StepDraft {
    /// One-line summary for list rows, e.g. "4× (Interval 400 m @ 1:45–1:55 /100m / Rest 30 s)".
    func summary(sport: EditorSport) -> String {
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
