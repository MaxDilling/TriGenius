import SwiftUI

// MARK: - Plan (ATP)
//
// The season-plan surface, laid out like a detail page: the next A race's readout,
// the season chart on the plain background, the events, then "About". The
// methodology + volume config sits in a setup sheet behind the toolbar's Setup button
// (Setup → Save → the deterministic engine recomputes and the chart updates).

struct ATPView: View {

    // Setup draft (mirrors ATPConfig + events).
    @State private var methodology: ATPMethodology = .weeklyTSS
    @State private var startDate = Date()
    @State private var recoveryCycle = 4
    @State private var autoCTL = true
    @State private var startingCTL = 50.0
    @State private var weeklyAverageTSS = 500.0
    @State private var maxRampRate = 7.0
    @State private var events: [ATPEventInput] = []

    @State private var plan: ATPPlan?
    @State private var editingEvent: ATPEventInput?
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
        .background(Color.appBackground)
        .navigationTitle("Plan")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            // A word, not a glyph: a pencil or gear leaves open whether it edits the
            // plan, an event or the app.
            ToolbarItem(placement: .primaryAction) { Button("Setup") { showingSetup = true } }
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

    // MARK: Setup sheet

    /// The methodology + volume config, presented from the toolbar's Setup button so the Plan
    /// page itself stays focused on the season chart + events. Events live on the page,
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
                    editingEvent = ATPEventInput(id: UUID().uuidString, name: "", date: startDate,
                                                 eventType: .triOlympic, priority: .a, targetCTL: nil, notes: "",
                                                 legs: ATPEventType.triOlympic.defaultLegs)
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
    private var upcomingEvents: [ATPEventInput] {
        let today = Calendar.current.startOfDay(for: Date())
        return events.filter { $0.date >= today }
    }

    private func eventRow(_ e: ATPEventInput) -> some View {
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
    private var targetEvent: ATPEventInput? { events.last { $0.priority == .a } }

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
        events = store.atpEvents()
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
    private func persistEvent(_ e: ATPEventInput) {
        TrainingDataStore.shared.upsertATPEvent(e)
        plan = ATPEngine.current()
    }

    private func deleteEvent(_ id: String) {
        events.removeAll { $0.id == id }
        TrainingDataStore.shared.deleteATPEvent(id: id)
        plan = ATPEngine.current()
    }
}

// MARK: - Event editor

private struct ATPEventEditSheet: View {
    @State var draft: ATPEventInput
    let showTargetCTL: Bool
    let onSave: (ATPEventInput) -> Void
    /// Non-nil only when editing an existing event (offers a Delete button).
    let onDelete: (() -> Void)?
    @Environment(\.dismiss) private var dismiss

    /// Discipline is derived from the type; changing it snaps to that discipline's first type.
    private var disciplineBinding: Binding<ATPEventDiscipline> {
        Binding(get: { draft.eventType.discipline },
                set: { setType(ATPEventType.types(in: $0).first ?? draft.eventType) })
    }

    private var typeBinding: Binding<ATPEventType> {
        Binding(get: { draft.eventType }, set: setType)
    }

    /// A new type starts from its standard legs.
    private func setType(_ type: ATPEventType) {
        guard type != draft.eventType else { return }
        draft.eventType = type
        draft.legs = type.defaultLegs
    }

    private var loads: [RaceLegLoad] {
        RaceLoad.legs(draft.legs, effort: draft.effort, thresholds: TrainingDataStore.shared.latestSnapshot())
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $draft.name)
                    DatePicker("Date", selection: $draft.date, displayedComponents: .date)
                    LabeledContent("Start") {
                        HStack {
                            if draft.startMinute != nil {
                                Button("Clear") { draft.startMinute = nil }.buttonStyle(.borderless)
                            }
                            DatePicker("Start", selection: startTime, displayedComponents: .hourAndMinute)
                                .labelsHidden()
                                .opacity(draft.startMinute == nil ? 0.5 : 1)
                        }
                    }
                    Picker("Discipline", selection: disciplineBinding) {
                        ForEach(ATPEventDiscipline.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Picker("Type", selection: typeBinding) {
                        ForEach(ATPEventType.types(in: draft.eventType.discipline), id: \.self) {
                            Text($0.label).tag($0)
                        }
                    }
                    Picker("Priority", selection: $draft.priority) {
                        ForEach(ATPEventPriority.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if showTargetCTL {
                        numberField("Target CTL", value: $draft.targetCTL, format: .number)
                        let s = ATPConstants.suggestedVolume(for: draft.eventType)
                        HStack {
                            Text("Suggested: \(Int(s.targetCTL.lowerBound))–\(Int(s.targetCTL.upperBound)) CTL")
                                .font(.caption2).foregroundStyle(.secondary)
                            Spacer()
                            Button("Apply") { draft.targetCTL = ((s.targetCTL.lowerBound + s.targetCTL.upperBound) / 2).rounded() }
                                .font(.caption2).buttonStyle(.borderless)
                        }
                    }
                }
                Section {
                    Picker("Effort", selection: $draft.effort) {
                        ForEach(RaceEffort.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Race")
                } footer: {
                    expectedLoad
                }
                ForEach(draft.legs.indices, id: \.self) { i in
                    Section(draft.legs.count > 1 ? draft.legs[i].sport.displayName : "Course") {
                        legFields($draft.legs[i])
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
        .frame(minWidth: 420, minHeight: 560)
        #endif
    }

    /// The race's expected load as the weekly target and PMC forecast count it;
    /// "~" while any leg's IF comes from the race curve rather than the athlete.
    private var expectedLoad: some View {
        let loads = loads
        let tss = loads.reduce(0) { $0 + $1.tss }
        let minutes = loads.reduce(0) { $0 + $1.minutes }
        let prefix = loads.contains(where: \.isEstimated) ? "~" : ""
        return Text(tss > 0
                    ? "Expected \(prefix)\(Int(tss.rounded())) TSS over \(durationHM(minutes)). Goal times and IF override the effort."
                    : "Set a distance or goal time to estimate the race's load.")
    }

    @ViewBuilder
    private func legFields(_ leg: Binding<RaceLeg>) -> some View {
        let isSwim = leg.wrappedValue.sport == .swim
        numberField(isSwim ? "Distance (m)" : "Distance (km)", value: Binding(
            get: { leg.wrappedValue.distanceMeters > 0 ? leg.wrappedValue.distanceMeters / (isSwim ? 1 : 1000) : nil },
            set: { leg.wrappedValue.distanceMeters = max(0, ($0 ?? 0) * (isSwim ? 1 : 1000)) }
        ), format: .number)
        LabeledContent("Goal time") {
            TextField("", value: leg.goalMinutes, format: ClockFormat(), prompt: Text("h:mm:ss"))
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                #if os(iOS)
                .keyboardType(.numbersAndPunctuation)
                #endif
        }
        numberField("Intensity factor", value: Binding(
            get: { leg.wrappedValue.intensityFactor },
            set: { leg.wrappedValue.intensityFactor = $0.map { min(max($0, TSSConstants.ifRange.lowerBound), TSSConstants.ifRange.upperBound) } }
        ), format: .number.precision(.fractionLength(0...2)))
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
}

/// "H:MM:SS" ⇄ minutes. A value-bound field commits on submit, so a half-typed time
/// isn't reformatted mid-entry.
private struct ClockFormat: ParseableFormatStyle {
    var parseStrategy: Strategy { Strategy() }
    func format(_ minutes: Double) -> String { RaceLeg.clock(minutes: minutes) }

    struct Strategy: ParseStrategy {
        func parse(_ value: String) throws -> Double {
            guard let minutes = RaceLeg.minutes(fromClock: value), minutes > 0 else { throw CocoaError(.formatting) }
            return minutes
        }
    }
}
