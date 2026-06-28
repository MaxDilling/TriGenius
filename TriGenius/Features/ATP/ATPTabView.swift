import SwiftUI

// MARK: - ATP tab (Milestone 3 setup + Milestone 4 chart)
//
// A throwaway-free test surface for the ATP engine while the real Plan-tab
// replacement is built: the setup inputs live at the top (edit → Save → the
// deterministic engine recomputes), the season chart renders directly below. This
// deliberately duplicates the Plan tab for now; it replaces that logic later
// (ATP_TODO Milestone 4/5).

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
    @State private var loaded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                setupCard
                if let plan {
                    chartCard(plan)
                } else {
                    emptyHint
                }
            }
            .padding()
        }
        .navigationTitle("ATP")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .sheet(item: $editingEvent) { draft in
            ATPEventEditSheet(draft: draft, showTargetCTL: methodology == .targetCTL) { saved in
                if let i = events.firstIndex(where: { $0.id == saved.id }) { events[i] = saved }
                else { events.append(saved) }
                events.sort { $0.date < $1.date }
            }
        }
        .onAppear { if !loaded { load(); loaded = true } }
        .onReceive(NotificationCenter.default.publisher(for: .trainingDataDidChange)) { _ in
            plan = ATPEngine.current()
        }
    }

    // MARK: Setup

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
            } else {
                numberRow("Max ramp rate (CTL/wk)", value: $maxRampRate)
            }

            Divider()
            eventsSection

            Button(action: save) {
                Text("Save ATP").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(events.allSatisfy { $0.priority == .c })
        }
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
                                              eventType: "", priority: .a, targetCTL: nil)
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
            .onDelete { events.remove(atOffsets: $0) }
        }
    }

    private func eventRow(_ e: EventDraft) -> some View {
        HStack(spacing: Theme.Spacing.s) {
            Text(e.priority.rawValue)
                .font(.caption.bold()).foregroundStyle(e.priority.tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 0) {
                Text(e.name.isEmpty ? "Unnamed event" : e.name)
                Text(e.date.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            if let c = e.targetCTL { Text("\(Int(c)) CTL").font(.caption).foregroundStyle(.secondary) }
        }
        .contentShape(Rectangle())
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

    private func chartCard(_ plan: ATPPlan) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            if let next = plan.weeks.first(where: { ($0.weeksToNextEvent ?? -1) >= 0 }) {
                Text("\(next.period.label) · \(Int(next.plannedTSS)) TSS this week"
                     + (next.weeksToNextEvent.map { " · \($0) wk to event" } ?? ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
            ATPSeasonChart(plan: plan)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Spacing.l)
        .glassSurface(cornerRadius: Theme.Radius.l)
    }

    private var emptyHint: some View {
        Text("No ATP yet — set the volume and add an A/B event, then Save.")
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

    private func save() {
        let store = TrainingDataStore.shared
        store.saveATPParams(ATPParams(
            startDate: startDate, startingCTL: autoCTL ? nil : startingCTL,
            methodology: methodology, recoveryCycle: recoveryCycle,
            maxRampRate: maxRampRate, weeklyAverageTSS: weeklyAverageTSS))

        let keep = Set(events.map(\.id))
        for e in store.atpEvents() where !keep.contains(e.id) { store.deleteATPEvent(id: e.id) }
        for d in events {
            store.upsertATPEvent(ATPEventInput(
                id: d.id, name: d.name, date: d.date, eventType: d.eventType,
                priority: d.priority, targetCTL: d.targetCTL, notes: ""))
        }
        plan = ATPEngine.current()
    }
}

// MARK: - Event draft + editor

struct EventDraft: Identifiable, Hashable {
    let id: String
    var name: String
    var date: Date
    var eventType: String
    var priority: ATPEventPriority
    var targetCTL: Double?
}

private struct ATPEventEditSheet: View {
    @State var draft: EventDraft
    let showTargetCTL: Bool
    let onSave: (EventDraft) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $draft.name)
                DatePicker("Date", selection: $draft.date, displayedComponents: .date)
                TextField("Type (e.g. Olympic triathlon)", text: $draft.eventType)
                Picker("Priority", selection: $draft.priority) {
                    ForEach(ATPEventPriority.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                if showTargetCTL {
                    HStack {
                        Text("Target CTL")
                        Spacer()
                        TextField("optional", value: $draft.targetCTL, format: .number)
                            .multilineTextAlignment(.trailing).frame(width: 90)
                            #if os(iOS)
                            .keyboardType(.numberPad)
                            #endif
                    }
                }
            }
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
    }
}
