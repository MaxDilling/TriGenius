import SwiftUI

// MARK: - Plan tab (ATP)
//
// The season-plan surface, laid out like a detail page: the next A race's readout,
// the season chart on the plain background, the events, then "About". The
// methodology + volume config sits in a setup sheet behind the header's Setup pill
// (Setup → Save → the deterministic engine recomputes and the chart updates).

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
                    season(plan)
                } else {
                    emptyHint
                }
                eventsSection
                SectionHeading("About the season plan")
                Text("""
                    Your season plan works backwards from your races. It divides the months ahead into periods — Base builds your aerobic foundation, Build adds race-specific intensity, Peak and Race cut the load so you arrive fresh — and gives each week a training-load target that raises your fitness at a rate your body can absorb, with a lighter recovery week every three or four weeks.

                    Give every race a priority. The plan builds towards your A races and tapers for two weeks before each; a B race gets a one-week taper; C races are training days the plan doesn't change for.

                    Each week's target becomes the weekly goal on your dashboard, and your coach plans your workouts around it. If a week will look different — a holiday, a work trip — pin its load, and the other weeks adjust to keep the season on track.
                    """)
                    .font(.subheadline).foregroundStyle(.secondary)
                    .contentCard()
            }
            .padding(Theme.Spacing.l)
        }
        .safeAreaBar(edge: .top) {
            // A word, not a glyph: a pencil or gear leaves open whether it edits the
            // plan, an event or the app.
            ScreenHeader("Plan") {
                Button { showingSetup = true } label: {
                    Text("Setup").font(.subheadline.weight(.semibold)).headerSegment()
                }
                .buttonStyle(.plain)
                .headerPill()
            }
            .padding(.horizontal)
            .padding(.vertical, Theme.Spacing.s)
        }
        .background(Color.appBackground)
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
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

    // MARK: Setup sheet

    /// The methodology + volume config, presented from the toolbar edit button so the Plan
    /// tab itself stays focused on the season chart + events. Events live on the tab,
    /// not here — they're the plan's content, not a setting.
    private var setupSheet: some View {
        NavigationStack {
            ScrollView { setupCard.padding() }
                .background(Color.appBackground)
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
        .cardSurface()
    }

    // MARK: Events (below the chart)

    private var eventsSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            SectionHeading("Events") {
                Button {
                    editingEvent = EventDraft(id: UUID().uuidString, name: "", date: startDate,
                                              eventType: .triOlympic, priority: .a, targetCTL: nil)
                } label: { Image(systemName: "plus") }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .accessibilityLabel("Add event")
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                if events.isEmpty {
                    Text("Add at least one A/B event to anchor the plan.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(upcomingEvents) { e in
                    Button { editingEvent = e } label: { eventRow(e) }
                        .buttonStyle(.plain)
                }
            }
            .contentCard()
        }
    }

    /// What the list shows. Display only — `events` keeps every race, so the plan
    /// engine still periodises against past ones and `targetEvent` still resolves.
    private var upcomingEvents: [EventDraft] {
        let today = Calendar.current.startOfDay(for: Date())
        return events.filter { $0.date >= today }
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
            Chevron()
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

    @ViewBuilder
    private func season(_ plan: ATPPlan) -> some View {
        let today = Calendar.current.startOfDay(for: Date())
        if let race = plan.events.filter({ $0.priority == .a && $0.date >= today }).min(by: { $0.date < $1.date }),
           let raceCTL = plan.plannedCTL(on: race.date) {
            readout(race, raceCTL: raceCTL, today: today, plan: plan)
        }
        ATPSeasonChart(
            plan: plan,
            onPinWeek: { week, tss in
                TrainingDataStore.shared.setATPOverride(weekStart: week, pinnedTSS: tss)
            },
            onUnpinWeek: { week in
                TrainingDataStore.shared.clearATPOverride(weekStart: week)
            })
    }

    /// Health-style readout: the fitness the plan builds for the next A race, and how
    /// today's actual fitness stands against the plan's.
    private func readout(_ race: ATPEventInput, raceCTL: Double, today: Date, plan: ATPPlan) -> some View {
        let weeks = Calendar.current.dateComponents([.weekOfYear], from: today, to: race.date).weekOfYear ?? 0
        let gap = plan.fitnessGap(on: today)
        return VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Circle().fill(Theme.Palette.fitness).frame(width: 9, height: 9)
                Text("\(Int(raceCTL.rounded()))").font(.largeTitle.bold()).monospacedDigit()
                Text("CTL").font(.subheadline).foregroundStyle(.secondary)
                if let gap { gapLabel(gap, band: plan.maxRampRate) }
            }
            Text([race.name.isEmpty ? "Unnamed event" : race.name, "A race",
                  race.date.formatted(.dateTime.day().month(.abbreviated).year()),
                  weeks > 0 ? "in \(weeks) wk" : "this week"].joined(separator: " · "))
                .font(.subheadline).foregroundStyle(.secondary)
        }
    }

    /// Within one week of max ramp either side counts as on plan. Off it in either
    /// direction is a warning: fitness above the plan means load rose faster than planned.
    private func gapLabel(_ gap: Double, band: Double) -> some View {
        let onPlan = abs(gap) <= band
        return HStack(spacing: 2) {
            if !onPlan { Image(systemName: gap < 0 ? "arrow.down" : "arrow.up") }
            Text(onPlan ? "on plan today" : "\(Int(abs(gap).rounded())) \(gap < 0 ? "below" : "above") plan today")
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(onPlan ? Theme.Palette.success : Theme.Palette.warning)
        .padding(.leading, Theme.Spacing.s)
    }

    private var emptyHint: some View {
        Text("No plan yet — tap Setup to set your volume and add an A/B event, then Save.")
            .font(.callout).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, Theme.Spacing.xl)
    }

    // MARK: Load / save

    private func load() {
        let perf = Perf.begin("ATP.load"); defer { Perf.end(perf) }
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
