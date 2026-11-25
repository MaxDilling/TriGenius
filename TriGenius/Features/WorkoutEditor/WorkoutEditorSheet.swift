import SwiftUI

// MARK: - Workout editor sheet
//
// The manual create/edit form for planned workouts and library templates,
// reached from the calendar's "+", the library, and the planned-workout
// detail's Edit. A full-state form over `WorkoutDraft`; saving a plan routes
// through `DataSyncCoordinator`'s shared plan CRUD — the exact write path the
// coach's scheduling tools use — and a template through `saveTemplate`, the same
// normalization. A strength session is edited in place: each exercise a row
// that expands (`ExerciseEditorRow`), each circuit its own section.

/// What the sheet edits.
enum WorkoutEditorContext: Identifiable {
    case create(date: Date)
    case edit(WorkoutRecord)
    /// A new plan on `date`, prefilled from a library template.
    case fromTemplate(WorkoutTemplate, date: Date)
    /// A library template itself; nil for a new one.
    case template(WorkoutTemplate?)

    var id: String {
        switch self {
        case .create(let date): return "create-\(date.timeIntervalSinceReferenceDate)"
        case .edit(let record): return "edit-\(record.id)"
        case .fromTemplate(let template, let date): return "from-\(template.id)-\(date.timeIntervalSinceReferenceDate)"
        case .template(let template): return "template-\(template?.id ?? "new")"
        }
    }
}

struct WorkoutEditorSheet: View {
    private let context: WorkoutEditorContext
    @State private var draft: WorkoutDraft
    @State private var saving = false
    @State private var validationError: String?
    @State private var templateSave: [String]?
    /// The exercise row shown expanded — one at a time.
    @State private var expanded: UUID?
    @State private var picking: PickTarget?
    @Environment(\.dismiss) private var dismiss

    private enum PickTarget: Equatable {
        /// New exercises, at the end or into the circuit with this id.
        case add(into: UUID?)
        case replace(UUID)
    }

    @MainActor
    init(context: WorkoutEditorContext) {
        self.context = context
        let draft = switch context {
        case .create(let date): WorkoutDraft(date: date)
        case .edit(let record): WorkoutDraft(record: record)
        case .fromTemplate(let template, let date): WorkoutDraft(workoutData: template.workoutData, date: date)
        case .template(let template?): WorkoutDraft(workoutData: template.workoutData, date: .now)
        case .template(nil): WorkoutDraft(date: .now, sport: .strength)
        }
        _draft = State(initialValue: draft)
    }

    private var isTemplate: Bool {
        if case .template = context { return true }
        return false
    }

    private var title: String {
        switch context {
        case .create, .fromTemplate: return "New Workout"
        case .edit: return "Edit \(draft.sport.label) Workout"
        case .template(let template): return template == nil ? "New Template" : "Edit Template"
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                basicsSection
                if draft.sport == .strength {
                    strengthSections
                } else {
                    stepsSection
                }
                if !isTemplate {
                    Section {
                        Button("Save as Template", systemImage: "square.stack") {
                            templateSave = TrainingDataStore.shared.saveTemplate(draft.workoutData())
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Save") { Task { await save() } }
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .exercisePicker(isPresented: Binding(get: { picking != nil }, set: { if !$0 { picking = nil } }),
                            multiple: !isReplacing, onPick: picked)
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 560)
        #endif
        .alert("Can't Save Workout", isPresented: Binding(get: { validationError != nil }, set: { if !$0 { validationError = nil } })) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(validationError ?? "")
        }
        .templateSaveAlert($templateSave)
    }

    // MARK: Basics

    private var basicsSection: some View {
        Section("Workout") {
            TextField("Name", text: $draft.name, prompt: Text(WorkoutNormalizer.defaultName(draft.workoutData())))
            // A plan's sport is fixed once it exists — the title names it.
            switch context {
            case .create, .fromTemplate, .template(nil):
                Picker("Sport", selection: $draft.sport) {
                    ForEach(EditorSport.allCases) { sport in
                        Label(sport.label, systemImage: sport.family.icon).tag(sport)
                    }
                }
            case .edit, .template:
                EmptyView()
            }
            if !isTemplate {
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

    // MARK: Steps (endurance)

    private var stepsSection: some View {
        Section {
            ForEach($draft.steps) { $step in
                NavigationLink {
                    StepEditorView(step: $step, sport: draft.sport)
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
                Button("Step", systemImage: "plus") { draft.steps.append(StepDraft()) }
                Button("Repeat block", systemImage: "plus") { draft.steps.append(StepDraft(isRepeat: true)) }
            }
        } header: {
            Text("Steps")
        } footer: {
            Text("Leave empty to auto-build a warm-up / main / cool-down structure from the duration or distance goal.")
        }
    }

    // MARK: Exercises (strength)

    /// Top-level steps in sections: each circuit its own, the steps between
    /// circuits together.
    private var strengthGroups: [[StepDraft]] {
        draft.steps.reduce(into: []) { groups, step in
            if step.isRepeat || groups.last?.last?.isRepeat ?? true {
                groups.append([step])
            } else {
                groups[groups.count - 1].append(step)
            }
        }
    }

    @ViewBuilder
    private var strengthSections: some View {
        ForEach(strengthGroups, id: \.first?.id) { group in
            if let circuit = group.first, circuit.isRepeat {
                circuitSection(circuit)
            } else {
                Section {
                    ForEach(group) { strengthRow($0, in: nil) }
                        .onDelete { offsets in offsets.forEach { draft.steps.remove(id: group[$0].id) } }
                }
            }
        }
        Section {
            Button("Add Exercises", systemImage: "plus") { picking = .add(into: nil) }
        } footer: {
            Text(draft.steps.isEmpty
                 ? "Leave empty for an unstructured, duration-only session."
                 : "Long-press an exercise to group it with the next into a circuit.")
        }
    }

    private func circuitSection(_ circuit: StepDraft) -> some View {
        Section("Circuit") {
            Stepper(value: binding(circuit.id).repeatCount, in: 2...50) {
                LabeledContent("Rounds", value: "\(circuit.repeatCount)")
            }
            RestMenu(title: "Rest between rounds", rest: binding(circuit.id).roundRest, allowsLap: false)
            ForEach(circuit.children) { strengthRow($0, in: circuit.id) }
                .onDelete { offsets in offsets.forEach { draft.steps.remove(id: circuit.children[$0].id) } }
            addButtons {
                Button("Exercise", systemImage: "plus") { picking = .add(into: circuit.id) }
                Button("Ungroup", systemImage: "rectangle.split.1x2") { ungroup(circuit.id) }
            }
        }
    }

    /// An exercise row — or a rest step that follows no exercise. Reorders by
    /// drag within its list; macOS has no swipe-to-delete, so the context menu
    /// deletes too.
    private func strengthRow(_ step: StepDraft, in circuit: UUID?) -> some View {
        Group {
            if step.isExercise {
                ExerciseEditorRow(step: binding(step.id),
                                  isExpanded: Binding(get: { expanded == step.id }, set: { expanded = $0 ? step.id : nil }),
                                  pausesAfter: circuit == nil) { picking = .replace(step.id) }
            } else {
                RestMenu(title: "Rest", rest: binding(step.id).restStepPause)
            }
        }
        .reorderable(step.id, in: circuit.map { id in binding(id).children } ?? $draft.steps)
        .contextMenu {
            if step.isExercise {
                Button("Replace Exercise", systemImage: "arrow.triangle.2.circlepath") { picking = .replace(step.id) }
                if circuit == nil, canGroup(step.id) {
                    Button("Group with Next", systemImage: "rectangle.stack") { groupWithNext(step.id) }
                }
            }
            Button("Delete", systemImage: "trash", role: .destructive) { draft.steps.remove(id: step.id) }
        }
    }

    /// The step with `id`, wherever it sits — rows bind by id, never by index,
    /// so a deletion can't leave a row reading past the end.
    private func binding(_ id: UUID) -> Binding<StepDraft> {
        Binding(get: { draft.steps.step(id: id) ?? StepDraft() },
                set: { new in draft.steps.update(id: id) { $0 = new } })
    }

    private var isReplacing: Bool {
        if case .replace = picking { return true }
        return false
    }

    private func picked(_ choices: [ExerciseChoice]) {
        switch picking {
        case .add(let circuit):
            var added = choices.map(StepDraft.exercise)
            if let circuit {
                for i in added.indices { added[i].joinCircuit() }
                draft.steps.update(id: circuit) { $0.children += added }
            } else {
                draft.steps += added
            }
            if added.count == 1 { expanded = added[0].id }
        case .replace(let id):
            guard let choice = choices.first else { return }
            draft.steps.update(id: id) { $0.choose(choice) }
        case nil:
            break
        }
    }

    private func canGroup(_ id: UUID) -> Bool {
        guard let i = draft.steps.firstIndex(where: { $0.id == id }), draft.steps.indices.contains(i + 1) else { return false }
        return draft.steps[i + 1].isExercise || draft.steps[i + 1].isRepeat
    }

    /// Joins an exercise with the next step into a circuit — the next
    /// exercise's, or the circuit it already starts. Each member does one set a
    /// round, so a new circuit runs as many rounds as the members had sets.
    private func groupWithNext(_ id: UUID) {
        guard let i = draft.steps.firstIndex(where: { $0.id == id }), draft.steps.indices.contains(i + 1) else { return }
        var member = draft.steps.remove(at: i)
        var next = draft.steps[i]
        if next.isRepeat {
            member.joinCircuit()
            next.children.insert(member, at: 0)
        } else {
            var circuit = StepDraft(isRepeat: true)
            circuit.repeatCount = min(max(member.exerciseSets, next.exerciseSets, 2), 50)
            member.joinCircuit()
            next.joinCircuit()
            circuit.children = [member, next]
            next = circuit
        }
        draft.steps[i] = next
    }

    /// Splits a circuit back into exercises, each doing all its rounds' sets.
    private func ungroup(_ id: UUID) {
        guard let i = draft.steps.firstIndex(where: { $0.id == id }) else { return }
        let circuit = draft.steps.remove(at: i)
        let members = circuit.children.map { member -> StepDraft in
            var member = member
            member.exerciseSets = min(member.exerciseSets * circuit.repeatCount, 20)
            return member
        }
        draft.steps.insert(contentsOf: members, at: i)
    }

    // MARK: Save

    /// Local write first (source of truth); a failed target push is non-fatal —
    /// `reconcileWriteTarget` re-pushes, same contract as drag-to-reschedule.
    private func save() async {
        saving = true
        let day = Calendar.current.startOfDay(for: draft.date)
        var errors: [String] = []
        switch context {
        case .edit(let record):
            if case .rejected(let rejected) = await DataSyncCoordinator.shared.updatePlan(id: record.id, workoutData: draft.workoutData()) {
                errors = rejected
            } else {
                if day != Calendar.current.startOfDay(for: record.date) {
                    _ = await DataSyncCoordinator.shared.movePlan(id: record.id, to: day)
                }
                if draft.startMinute != record.startMinute {
                    _ = TrainingDataStore.shared.setScheduledStartMinute(id: record.id, minute: draft.startMinute)
                }
            }
        case .create, .fromTemplate:
            if case .rejected(let rejected) = await DataSyncCoordinator.shared.addPlan(workoutData: draft.workoutData(), date: day,
                                                                                    startMinute: draft.startMinute) {
                errors = rejected
            }
        case .template(let template):
            errors = TrainingDataStore.shared.saveTemplate(draft.workoutData(), replacing: template)
        }
        guard errors.isEmpty else {
            validationError = errors.joined(separator: "\n")
            saving = false
            return
        }
        dismiss()
    }
}

extension Array where Element == StepDraft {
    /// The step with `id`, at the top level or inside a circuit.
    func step(id: UUID) -> StepDraft? {
        for step in self {
            if step.id == id { return step }
            if let child = step.children.step(id: id) { return child }
        }
        return nil
    }

    mutating func update(id: UUID, _ change: (inout StepDraft) -> Void) {
        for i in indices {
            if self[i].id == id { return change(&self[i]) }
            self[i].children.update(id: id, change)
        }
    }

    mutating func remove(id: UUID) {
        removeAll { $0.id == id }
        for i in indices { self[i].children.remove(id: id) }
    }
}

extension View {
    /// The outcome of a "Save as Template": saved, or the plausibility errors
    /// that rejected it.
    func templateSaveAlert(_ result: Binding<[String]?>) -> some View {
        alert(result.wrappedValue?.isEmpty == false ? "Can't Save Template" : "Saved to Library",
              isPresented: Binding(get: { result.wrappedValue != nil }, set: { if !$0 { result.wrappedValue = nil } })) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(result.wrappedValue.map { $0.isEmpty ? "Plan it from the calendar’s + → From Library." : $0.joined(separator: "\n") } ?? "")
        }
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

/// "m:ss" ⇄ whole seconds — display-only.
enum MMSS {
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
