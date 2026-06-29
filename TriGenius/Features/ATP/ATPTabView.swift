import SwiftUI

// MARK: - Plan tab (ATP)
//
// The season-plan surface: the chart fills the tab, while the methodology + volume
// config and event list sit in a setup sheet behind the toolbar gear (edit → Save →
// the deterministic engine recomputes and the chart updates).

struct ATPTabView: View {

    // Setup draft (mirrors ATPConfig + events).
    @State private var methodology: ATPMethodology = .weeklyTSS
    @State private var startDate = Date()
    @State private var recoveryCycle = 4
    @State private var autoCTL = true
    @State private var startingCTL = 50.0
    @State private var weeklyAverageTSS = 500.0
    @State private var maxRampRate = 7.0
    @State private var events: [EventDraft] = []

    @State private var plan: ATPPlan?
    @State private var editingEvent: EventDraft?
    @State private var showingSetup = false
    @State private var loaded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                if let plan {
                    chartCard(plan)
                } else {
                    emptyHint
                }
                eventsCard
            }
            .padding()
        }
        .navigationTitle("Plan")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showingSetup = true } label: { Image(systemName: "gearshape") }
                    .accessibilityLabel("Plan setup")
            }
        }
        .sheet(isPresented: $showingSetup) { setupSheet }
        .sheet(item: $editingEvent) { draft in
            let isExisting = events.contains { $0.id == draft.id }
            ATPEventEditSheet(
                draft: draft, showTargetCTL: methodology == .targetCTL,
                onSave: { saved in
                    if let i = events.firstIndex(where: { $0.id == saved.id }) { events[i] = saved }
                    else { events.append(saved) }
                    events.sort { $0.date < $1.date }
                    persistEvent(saved)
                },
                onDelete: isExisting ? { deleteEvent(draft.id) } : nil)
        }
        .onAppear { if !loaded { load(); loaded = true } }
        .onReceive(NotificationCenter.default.publisher(for: .trainingDataDidChange)) { _ in
            plan = ATPEngine.current()
        }
    }

    // MARK: Setup (behind the gear)

    /// The methodology + volume config, presented from the toolbar gear so the Plan
    /// tab itself stays focused on the season chart + events. Events live on the tab,
    /// not here — they're the plan's content, not a setting.
    private var setupSheet: some View {
        NavigationStack {
            ScrollView { setupCard.padding() }
                .navigationTitle("Plan Setup")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showingSetup = false }
                    }
                }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 480)
        #endif
    }

    private var setupCard: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            Picker("Methodology", selection: $methodology) {
                Text("Weekly TSS").tag(ATPMethodology.weeklyTSS)
                Text("Target CTL").tag(ATPMethodology.targetCTL)
            }
            .pickerStyle(.segmented)

            DatePicker("Start", selection: $startDate, displayedComponents: .date)

            Stepper("Recovery every \(recoveryCycle) weeks", value: $recoveryCycle, in: 3...4)

            Toggle("Use current fitness as starting CTL", isOn: $autoCTL)
            if !autoCTL {
                numberRow("Starting CTL", value: $startingCTL)
            }

            if methodology == .weeklyTSS {
                numberRow("Weekly average TSS", value: $weeklyAverageTSS)
                if let ev = targetEvent {
                    let s = ATPConstants.suggestedVolume(for: ev.eventType)
                    suggestionHint(
                        "Suggested for \(ev.eventType.label): \(Int(s.weeklyTSS.lowerBound))–\(Int(s.weeklyTSS.upperBound)) TSS",
                        apply: { weeklyAverageTSS = ((s.weeklyTSS.lowerBound + s.weeklyTSS.upperBound) / 2).rounded() })
                }
            } else {
                numberRow("Max ramp rate (CTL/wk)", value: $maxRampRate)
            }

            Button(action: save) {
                Text("Save").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(cornerRadius: Theme.Radius.l, padding: Theme.Spacing.l)
    }

    // MARK: Events (below the chart)

    private var eventsCard: some View {
        eventsSection
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface(cornerRadius: Theme.Radius.l, padding: Theme.Spacing.l)
    }

    private var eventsSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            HStack {
                Text("Events").font(.headline)
                Spacer()
                Button {
                    editingEvent = EventDraft(id: UUID().uuidString, name: "", date: startDate,
                                              eventType: .triOlympic, priority: .a, targetCTL: nil)
                } label: { Image(systemName: "plus.circle.fill") }
            }
            if events.isEmpty {
                Text("Add at least one A/B event to anchor the plan.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(events) { e in
                Button { editingEvent = e } label: { eventRow(e) }
                    .buttonStyle(.plain)
            }
        }
    }

    private func eventRow(_ e: EventDraft) -> some View {
        HStack(spacing: Theme.Spacing.s) {
            Text(e.priority.rawValue)
                .font(.caption.bold()).foregroundStyle(e.priority.tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 0) {
                Text(e.name.isEmpty ? "Unnamed event" : e.name)
                Text("\(e.eventType.discipline.label) · \(e.eventType.label) · "
                     + e.date.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            if let c = e.targetCTL { Text("\(Int(c)) CTL").font(.caption).foregroundStyle(.secondary) }
        }
        .contentShape(Rectangle())
    }

    /// The season's target race (last A event) — drives the suggested-volume hint.
    private var targetEvent: EventDraft? { events.last { $0.priority == .a } }

    private func suggestionHint(_ text: String, apply: @escaping () -> Void) -> some View {
        HStack {
            Text(text).font(.caption2).foregroundStyle(.secondary)
            Spacer()
            Button("Apply", action: apply).font(.caption2).buttonStyle(.borderless)
        }
    }

    private func numberRow(_ title: String, value: Binding<Double>) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField(title, value: value, format: .number)
                .multilineTextAlignment(.trailing)
                .frame(width: 90)
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif
        }
    }

    // MARK: Chart

    /// The week whose Mon–Sun span contains today; falls back to the first upcoming
    /// week (e.g. a plan that starts in the future).
    private func currentWeek(_ plan: ATPPlan) -> ATPWeekPlan? {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        return plan.weeks.first { wk in
            let end = cal.date(byAdding: .day, value: 6, to: wk.weekStart) ?? wk.weekStart
            return today >= wk.weekStart && today <= end
        } ?? plan.weeks.first { ($0.weeksToNextEvent ?? -1) >= 0 }
    }

    private func chartCard(_ plan: ATPPlan) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            if let current = currentWeek(plan) {
                Text("\(current.period.label) · \(Int(current.plannedTSS)) TSS this week"
                     + (current.weeksToNextEvent.map { " · \($0) wk to event" } ?? ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
            ATPSeasonChart(plan: plan) { week, tss in
                TrainingDataStore.shared.setATPOverride(weekStart: week, pinnedTSS: tss)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Spacing.l)
        .glassSurface(cornerRadius: Theme.Radius.l)
    }

    private var emptyHint: some View {
        Text("No plan yet — tap the gear to set your volume and add an A/B event, then Save.")
            .font(.callout).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, Theme.Spacing.xl)
    }

    // MARK: Load / save

    private func load() {
        let store = TrainingDataStore.shared
        if let p = store.atpParams() {
            methodology = p.methodology
            startDate = p.startDate
            recoveryCycle = p.recoveryCycle
            maxRampRate = p.maxRampRate
            weeklyAverageTSS = p.weeklyAverageTSS
            if let c = p.startingCTL { autoCTL = false; startingCTL = c } else { autoCTL = true }
        }
        events = store.atpEvents().map {
            EventDraft(id: $0.id, name: $0.name, date: $0.date, eventType: $0.eventType,
                       priority: $0.priority, targetCTL: $0.targetCTL)
        }
        plan = ATPEngine.current()
    }

    /// Save the methodology + volume config only — events persist on edit (see
    /// `persistEvent`/`deleteEvent`). The engine re-periodizes around the existing
    /// events and pins.
    private func save() {
        TrainingDataStore.shared.saveATPParams(ATPParams(
            startDate: startDate, startingCTL: autoCTL ? nil : startingCTL,
            methodology: methodology, recoveryCycle: recoveryCycle,
            maxRampRate: maxRampRate, weeklyAverageTSS: weeklyAverageTSS))
        plan = ATPEngine.current()
        showingSetup = false           // back to the chart, now showing the saved plan
    }

    /// Upsert one event to the store and re-periodize — each event edit takes effect
    /// immediately, no Save step (the config keeps its own Save in the gear sheet).
    private func persistEvent(_ d: EventDraft) {
        TrainingDataStore.shared.upsertATPEvent(ATPEventInput(
            id: d.id, name: d.name, date: d.date, eventType: d.eventType,
            priority: d.priority, targetCTL: d.targetCTL, notes: ""))
        plan = ATPEngine.current()
    }

    private func deleteEvent(_ id: String) {
        events.removeAll { $0.id == id }
        TrainingDataStore.shared.deleteATPEvent(id: id)
        plan = ATPEngine.current()
    }
}

// MARK: - Event draft + editor

struct EventDraft: Identifiable, Hashable {
    let id: String
    var name: String
    var date: Date
    var eventType: ATPEventType
    var priority: ATPEventPriority
    var targetCTL: Double?
}

private struct ATPEventEditSheet: View {
    @State var draft: EventDraft
    let showTargetCTL: Bool
    let onSave: (EventDraft) -> Void
    /// Non-nil only when editing an existing event (offers a Delete button).
    let onDelete: (() -> Void)?
    @Environment(\.dismiss) private var dismiss

    /// Discipline is derived from the type; changing it snaps to that discipline's first type.
    private var disciplineBinding: Binding<ATPEventDiscipline> {
        Binding(get: { draft.eventType.discipline },
                set: { draft.eventType = ATPEventType.types(in: $0).first ?? draft.eventType })
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $draft.name)
                DatePicker("Date", selection: $draft.date, displayedComponents: .date)
                Picker("Discipline", selection: disciplineBinding) {
                    ForEach(ATPEventDiscipline.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Picker("Type", selection: $draft.eventType) {
                    ForEach(ATPEventType.types(in: draft.eventType.discipline), id: \.self) {
                        Text($0.label).tag($0)
                    }
                }
                Picker("Priority", selection: $draft.priority) {
                    ForEach(ATPEventPriority.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                if showTargetCTL {
                    TextField("Target CTL", value: $draft.targetCTL, format: .number, prompt: Text("optional"))
                        .multilineTextAlignment(.trailing)
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                    let s = ATPConstants.suggestedVolume(for: draft.eventType)
                    HStack {
                        Text("Suggested: \(Int(s.targetCTL.lowerBound))–\(Int(s.targetCTL.upperBound)) CTL")
                            .font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        Button("Apply") { draft.targetCTL = ((s.targetCTL.lowerBound + s.targetCTL.upperBound) / 2).rounded() }
                            .font(.caption2).buttonStyle(.borderless)
                    }
                }
                if let onDelete {
                    Button("Delete Event", role: .destructive) { onDelete(); dismiss() }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Event")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave(draft); dismiss() }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 380)
        #endif
    }
}
