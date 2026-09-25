import SwiftUI
import Combine

// MARK: - Dashboard View
//
// The athlete's home screen. A `ScreenHeader` greeting the athlete by name, with
// Settings as its one control and the plan line (current ATP period + countdown to
// the next A event → Plan tab) under it, then the `DashboardSection` blocks in the
// athlete's configured order/visibility (`AppSettings.dashboardLayout`):
//   • Up Next: today's completed + upcoming planned workouts, one row per
//     workout → its detail screen.
//   • Fitness & Form: CTL / ATL / TSB summary tiles and fitness vs the ATP plan
//     → StatisticsView.
//   • Tissue Load: the structural load card → its grid / group detail.
//   • Weekly Target (Volume): per-discipline rings, actual vs. target → Plan tab.
//   • AI insight: the coach's one-line read on the week → chat, prefilled.
//
// Everything that leads somewhere carries a `Chevron`.
//
// Everything reads from the local DB via DashboardViewModel (source-agnostic).

struct DashboardView: View {
    let readSources: Set<DataSource>
    var athleteName: String?
    let weeklyStructure: WeeklyStructure
    @ObservedObject var memory: CoachMemory
    let makeBackend: () -> LLMBackend
    // Settings is reached from the dashboard header (BUGS.md: the calendar moved to
    // the tab bar, settings took its place here), so the screen needs what
    // `SettingsView` requires.
    let brain: CoachBrain
    @ObservedObject var settings: AppSettings
    let onBackendChanged: () -> Void

    @Environment(CoachRouter.self) private var router
    @State private var viewModel = DashboardViewModel()
    @State private var volumeMetric: VolumeMetric = .tss
    @State private var tissueMode: TissueCardMode = .sevenDays
    @State private var showsTissueGrid = false
    /// The group a tapped conflict warning opens.
    @State private var conflictGroup: TissueGroup?

    private var wide = WideLayout()

    private var context: DashboardContext {
        DashboardContext(
            readSources: readSources,
            weeklyStructure: weeklyStructure,
            makeBackend: makeBackend,
            aiInsightEnabled: settings.isVisible(.aiInsight)
        )
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.xl) {
                if viewModel.isLoading && viewModel.pmc == nil {
                    ProgressView("Loading…").padding(.top, 60)
                } else {
                    if let error = viewModel.errorMessage {
                        Text(error).font(.caption).foregroundStyle(Theme.Palette.danger)
                    }
                    header
                    ForEach(settings.dashboardLayout.filter(\.isVisible)) { item in
                        sectionView(item.section)
                    }
                }
            }
            .padding(Theme.Spacing.l)
        }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        #endif
        // Unstructured Task so the sync survives the reloads it triggers along the way
        // (`trainingDataDidChange` fires mid-sync from the metrics ingest, re-rendering
        // this view) — `.refreshable`'s own task gets cancelled by that re-render before
        // the Garmin fetch for new workouts even starts, which is why a manual pull
        // silently missed new activities that only showed up after an app restart.
        .refreshable { await Task { await viewModel.refresh(context: context) }.value }
        .task { await viewModel.loadInitialIfNeeded(context: context) }
        // Any local-store mutation (coach `add_workout`, a sync, a Calendar
        // reschedule/delete) updates the DB but not this view's cached snapshot;
        // reload (no network) when it changes.
        .onReceive(NotificationCenter.default.publisher(for: .trainingDataDidChange)) { _ in
            Task { await viewModel.load(context: context) }
        }
        // The ATP lives in SwiftData and posts `trainingDataDidChange` on every
        // change, so the notification above already reloads when the plan moves.
        // `weeklyStructure` (the sport-split ratio) lives in `coach_memory.json`, so
        // a coach edit there bypasses that notification — reload on its signature.
        // `.onChange` fires after the new value is in place, so `context` already
        // carries the fresh structure.
        .onChange(of: structureSignature) {
            Task { await viewModel.load(context: context) }
        }
        // Toggling the AI summary on/off (Settings → Dashboard layout) — generate or
        // clear the insight without a full sync. Watches only this section's
        // visibility, not the whole layout, so a mere reorder never re-loads.
        .onChange(of: settings.isVisible(.aiInsight)) {
            Task { await viewModel.load(context: context) }
        }
    }

    /// Renders one configurable dashboard section (order + visibility come from
    /// `AppSettings.dashboardLayout`; the header stays fixed above them).
    @ViewBuilder private func sectionView(_ section: DashboardSection) -> some View {
        switch section {
        case .upNext: upNext
        case .performance: fitnessAndForm
        case .tissueLoad: tissueLoad
        case .weeklyTarget: weeklyTarget
        case .aiInsight: aiInsightCard
        }
    }

    /// Cheap, DB-free fingerprint of the non-DB inputs the weekly targets depend on
    /// (the sport-split ratio/floors), so a coach-driven structure edit triggers a
    /// dashboard reload.
    ///
    /// Built from a key-sorted JSON encoding, NOT `"\(dict)"`: a `[String: Any]`
    /// has no stable iteration order (it depends on the per-process random hash
    /// seed), so interpolating it produces a string that "flaps" between renders
    /// even when unchanged — which made `.onChange` fire every render and spun a
    /// 100×/s reload loop. `.sortedKeys` makes the fingerprint depend only on content.
    private var structureSignature: String {
        Self.stableJSON(weeklyStructure.toDict())
    }

    private static func stableJSON(_ dict: [String: Any]) -> String {
        (try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            ScreenHeader(greeting) {
                NavigationLink {
                    SettingsView(
                        brain: brain,
                        settings: settings,
                        memory: memory,
                        onBackendChanged: onBackendChanged
                    )
                } label: {
                    Image(systemName: "gearshape").font(.title3)
                }
                .buttonStyle(.plain)
                .headerPill()
            }
            if let plan = viewModel.atpPlan, !plan.weeks.isEmpty {
                Button { router.selectedTab = .plan } label: { TrainingPlanBanner(plan: plan) }
                    .buttonStyle(.plain)
            }
        }
    }

    private var greeting: String {
        if let name = athleteName, !name.isEmpty { return "Hi \(name)" }
        return "Hi there"
    }

    // MARK: Fitness & Form

    private var fitnessAndForm: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            SectionHeading("Fitness & Form")
            if let result = viewModel.pmc, result.snapshot != nil {
                LazyVGrid(columns: SummaryTile.columns(wide: wide.isWide, fill: 3), spacing: Theme.Spacing.m) {
                    PMCStatTiles(result: result, range: .oneMonth) { StatisticsView() }
                }
                if !viewModel.ctlTrend.actual.isEmpty {
                    NavigationLink { StatisticsView() } label: { trendCard(result) }
                        .buttonStyle(.plain)
                }
            } else {
                Text("No training-load data yet. Sync your activities to see CTL / ATL / TSB.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .contentCard()
            }
        }
    }

    /// Actual fitness against the ATP plan around today, headed by this week's ramp.
    private func trendCard(_ result: PMCResult) -> some View {
        let ramp = RampRate.weeklySeries(points: result.points, weeks: 2).last.map { week in
            Text("\(week.delta.formatted(.number.precision(.fractionLength(1)).sign(strategy: .always()))) CTL/wk")
                .foregroundStyle(RampRate.safeBand.contains(week.delta) ? Theme.Palette.success
                                 : week.delta > RampRate.safeBand.upperBound ? Theme.Palette.warning : .secondary)
        }
        return VStack(alignment: .leading, spacing: Theme.Spacing.l) {
            CardHeader(title: "Fitness vs plan", color: Theme.Palette.fitness, detail: ramp)
            CTLTrendChart(model: viewModel.ctlTrend)
        }
        .contentCard()
    }

    // MARK: Tissue Load

    // A conflict warning opens the group it names — its detail explains the spike and
    // links the session.
    @ViewBuilder private var tissueLoad: some View {
        if let model = viewModel.tissueCard {
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                SectionHeading("Tissue Load") {
                    if viewModel.tissueChronic != nil {
                        SegmentedPicker("Window", selection: $tissueMode,
                                        options: TissueCardMode.allCases, label: \.label)
                    }
                }
                // Wide layouts have the room for the whole grid, so they skip the
                // card's edit down to three rows.
                if wide.isWide, let grid = viewModel.tissueGrid, tissueMode == .sevenDays {
                    VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                        TissueLeadRow(lead: model.lead, onResolveConflict: openConflict)
                        TissueGrid(days: grid.days, rows: grid.rows, isWide: true,
                                   onSelect: { _ in showsTissueGrid = true })
                        TissueLegend()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .cardSurface()
                } else {
                    TissueLoadCard(mode: tissueMode, model: model, chronic: viewModel.tissueChronic,
                                   onResolveConflict: openConflict,
                                   onSelect: { _ in showsTissueGrid = true },
                                   onAskCoach: { router.openChat(prefill: $0) })
                }
            }
            .navigationDestination(isPresented: $showsTissueGrid) {
                if let input = viewModel.tissueInput {
                    TissueLoadScreen(input: input, onAskCoach: { router.openChat(prefill: $0) })
                }
            }
            .navigationDestination(item: $conflictGroup) { group in
                if let input = viewModel.tissueInput, let detail = TissueGroupDetailModel.make(group: group, input: input) {
                    TissueGroupDetail(model: detail, onAskCoach: { router.openChat(prefill: $0) })
                }
            }
        }
    }

    private func openConflict() {
        conflictGroup = viewModel.tissueInput?.conflicts.first?.group
    }

    // MARK: Weekly Target (Volume)

    @ViewBuilder private var weeklyTarget: some View {
        if !viewModel.visibleFamilies.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                SectionHeading("Weekly Target") {
                    SegmentedPicker("Metric", selection: $volumeMetric,
                                    options: VolumeMetric.allCases, label: \.label)
                }

                HStack(alignment: wide.isWide ? .center : .top,
                       spacing: wide.isWide ? Theme.Spacing.l : 8) {
                    ForEach(viewModel.visibleFamilies) { family in
                        // Actual comes from the projection (its own weekly sum) so the
                        // solid arc and the projection arc share one number.
                        let target = viewModel.target(for: family)
                        let projection = viewModel.projection(for: family)
                        VolumeRing(family: family,
                                   metric: volumeMetric,
                                   horizontal: wide.isWide,
                                   actualTSS: projection.actualTSS,
                                   targetTSS: target.tss,
                                   actualKm: projection.actualKm,
                                   targetKm: target.distanceKm,
                                   projectedTSS: projection.projectedTSS,
                                   projectedKm: projection.projectedKm,
                                   creditedTSS: projection.creditedTSS,
                                   projectedCreditTSS: projection.projectedCreditTSS)
                    }
                    Chevron()
                }
                .contentCard()
                .contentShape(Rectangle())
                .onTapGesture { router.selectedTab = .plan }
            }
        }
    }

    // MARK: AI insight

    // The coach's read on the week (FEATURES.md "AI-generated dashboard insight"): a
    // plain sentence marked only by the coach hairline. A heuristic line is surfaced
    // instantly while the model line is generated. Tapping the card carries its read
    // into the chat as a pre-filled (unsent) prompt.
    @ViewBuilder private var aiInsightCard: some View {
        if let insight = viewModel.insight, !insight.isEmpty {
            let parsed = DashboardInsight.parse(insight)
            VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                CardHeader(title: "Coach", color: .accentColor)
                Text(parsed.text).font(.body.weight(.medium))
                // Its own button consumes the tap, so it routes the coach's specific
                // message rather than the card's generic follow-up.
                if let action = parsed.action {
                    Button(action.label) { router.openChat(prefill: action.message) }
                        .font(.footnote.weight(.semibold))
                        .buttonStyle(.glass)
                }
            }
            .contentCard()
            .coachAccent()
            .contentShape(Rectangle())
            .onTapGesture { router.openChat(prefill: viewModel.insightFollowUpPrompt) }
        }
    }

    // MARK: Up Next

    /// Every upcoming/today workout — completed and planned — flattened into a
    /// single list so they can share one tile with hairline dividers between rows.
    private var upNextItems: [UpNextItem] {
        var items: [UpNextItem] = []
        for day in viewModel.agendaDays {
            for record in day.completed {
                items.append(UpNextItem(date: day.date, record: record))
            }
            for planned in day.planned {
                items.append(UpNextItem(date: day.date, planned: planned))
            }
        }
        return items
    }

    private var upNext: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            SectionHeading("Up Next")

            let items = upNextItems
            if items.isEmpty {
                Text("No workouts logged or planned.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .contentCard()
            } else if wide.isWide, items.count > 3 {
                // Split in halves rather than interleaved: the agenda is date-sorted,
                // so each column stays chronological on its own.
                let split = (items.count + 1) / 2
                HStack(alignment: .top, spacing: 0) {
                    upNextColumn(Array(items.prefix(split)))
                    Divider()
                    upNextColumn(Array(items.dropFirst(split)))
                }
                .contentCard(padding: 0)
            } else {
                upNextColumn(items).contentCard(padding: 0)
            }
        }
    }

    private func upNextColumn(_ items: [UpNextItem]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index > 0 {
                    Divider().padding(.leading, 62).padding(.trailing, Theme.Spacing.m)
                }
                upNextRow(item)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// One compact row in the Up Next tile: date column, sport dot, title + summary.
    @ViewBuilder private func upNextRow(_ item: UpNextItem) -> some View {
        NavigationLink {
            if let record = item.record {
                TrainingDetailView(record: record)
            } else if let planned = item.planned {
                PlannedWorkoutDetailView(workout: planned)
            }
        } label: {
            HStack(spacing: Theme.Spacing.m) {
                dateColumn(item.date)

                ZStack {
                    Circle().fill(item.family.color.opacity(0.25))
                    Image(systemName: item.family.icon)
                        .font(.headline)
                        .foregroundStyle(item.family.color)
                }
                .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title).font(.headline).lineLimit(1)
                    Text(item.summary).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)

                if item.completed {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.Palette.success)
                }
                Chevron()
            }
            .padding(.vertical, Theme.Spacing.m)
            .padding(.horizontal, Theme.Spacing.l)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private func dateColumn(_ date: Date) -> some View {
        let isToday = Calendar.current.isDateInToday(date)
        return VStack(spacing: 2) {
            Text(date.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                .font(.caption).foregroundStyle(isToday ? Color.accentColor : .secondary)
            Text(date.formatted(.dateTime.day()))
                .font(.title2.bold())
                .foregroundStyle(isToday ? Color.accentColor : .primary)
        }
        .frame(width: 34)
    }
}

// MARK: - Up Next item

/// A flattened Up Next entry — either a completed activity or a planned workout —
/// exposing the common fields the shared row needs plus the source for navigation.
private struct UpNextItem: Identifiable {
    let date: Date
    let record: WorkoutRecord?
    let planned: WorkoutRecord?

    init(date: Date, record: WorkoutRecord) {
        self.date = date
        self.record = record
        self.planned = nil
    }
    init(date: Date, planned: WorkoutRecord) {
        self.date = date
        self.record = nil
        self.planned = planned
    }

    var id: String { record.map { "c-\($0.id)" } ?? planned.map { "p-\($0.id)" } ?? UUID().uuidString }
    var completed: Bool { record != nil }
    var family: SportFamily {
        if let record { return SportFamily(sportKey: record.sport) }
        return planned?.family ?? .other
    }
    var title: String { record?.name ?? planned?.name ?? "" }

    /// "{TSS} TSS · {duration}" — matches the compact mockup row.
    var summary: String {
        if let record {
            var parts: [String] = []
            if let tss = record.tss, tss > 0 { parts.append("\(Int(tss.rounded())) TSS") }
            parts.append(durationHM(record.durationMinutes))
            return parts.joined(separator: " · ")
        }
        return planned?.plannedSummaryLine() ?? ""
    }
}

// MARK: - Volume metric (TSS vs. distance)

/// Which metric the Weekly Target rings fill against and show on top. The other
/// metric drops to the secondary line below.
enum VolumeMetric: CaseIterable {
    case tss, distance

    var label: String { self == .tss ? "TSS" : "km" }
}

// MARK: - Volume Ring

private struct VolumeRing: View {
    let family: SportFamily
    let metric: VolumeMetric
    /// Wide layouts put the numbers beside the ring instead of under it, so three
    /// tiles fill the row rather than floating in it.
    var horizontal = false
    let actualTSS: Double
    let targetTSS: Double
    let actualKm: Double
    let targetKm: Double
    /// Expected week close (completed + still-planned) for the active metric —
    /// rendered as a faded arc continuing past the solid "actual" fill.
    let projectedTSS: Double
    let projectedKm: Double
    /// Cross-training credit (TSS only) borrowed from other disciplines' surplus,
    /// drawn as a distinct mid-opacity segment between the solid fill and the
    /// projection arc.
    let creditedTSS: Double
    let projectedCreditTSS: Double

    private var actual: Double { metric == .tss ? actualTSS : actualKm }
    private var target: Double { metric == .tss ? targetTSS : targetKm }
    private var projected: Double { max(metric == .tss ? projectedTSS : projectedKm, actual) }
    // Credit is TSS-only — distance doesn't transfer across sports.
    private var credited: Double { metric == .tss ? creditedTSS : 0 }
    private var projectedCredit: Double { metric == .tss ? projectedCreditTSS : 0 }

    private func fraction(_ value: Double) -> Double { target > 0 ? min(value / target, 1) : 0 }
    /// Solid fill: what the athlete actually did in this discipline.
    private var realTop: Double { fraction(actual) }
    /// End of the borrowed-credit segment (real + credit).
    private var creditTop: Double { fraction(actual + credited) }
    /// End of the projection arc (projected close + its credit).
    private var projTop: Double { fraction(projected + projectedCredit) }

    /// True once even the credited projected close falls short of the target — the
    /// visible gap that signals an at-risk week.
    private var fallsShort: Bool { target > 0 && projTop < 0.99 }

    var body: some View {
        let layout = horizontal ? AnyLayout(HStackLayout(spacing: Theme.Spacing.m))
                                : AnyLayout(VStackLayout(spacing: 8))
        layout {
            ZStack {
                Circle().stroke(Color.primary.opacity(0.10), lineWidth: 7)
                // Projection: the still-planned continuation beyond the completed
                // (solid) arc, up to the weekly target. Same 7pt radius as the
                // solid arc but dashed + lighter so it reads as "planned, not yet
                // done" rather than "done".
                if projTop > creditTop {
                    Circle()
                        .trim(from: creditTop, to: projTop)
                        .stroke(family.color.opacity(0.65),
                                style: StrokeStyle(lineWidth: 7, lineCap: .butt, dash: [2, 2]))
                        .rotationEffect(.degrees(-90))
                }
                // Cross-training credit: mid-opacity solid segment past the real
                // fill, so borrowed load reads as borrowed rather than done.
                if creditTop > realTop {
                    Circle()
                        .trim(from: realTop, to: creditTop)
                        .stroke(family.color.opacity(0.80),
                                style: StrokeStyle(lineWidth: 7, lineCap: .butt))
                        .rotationEffect(.degrees(-90))
                }
                Circle()
                    .trim(from: 0, to: realTop)
                    .stroke(family.color, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: family.icon).font(.title3).foregroundStyle(family.color)
            }
            .frame(width: 60, height: 60)

            VStack(alignment: horizontal ? .leading : .center, spacing: 1) {
                Text(label(metric, actual)).font(.subheadline.weight(.semibold))
                if target > 0 {
                    Text("/ \(label(metric, target))").font(.caption2).foregroundStyle(.secondary)
                }
                if projected > actual {
                    // The expected close given what is still planned this week —
                    // tertiary (lighter) when on track, amber only when at risk.
                    Text("→ \(label(metric, projected))")
                        .font(.caption2)
                        .foregroundStyle(fallsShort ? Theme.Palette.warning : Color.secondary.opacity(0.6))
                        .padding(.top, 1)
                }
                
                Text(label(secondaryMetric, secondaryActual))
                    .font(.caption.weight(.semibold)).foregroundStyle(family.color)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: horizontal ? .leading : .center)
    }

    private var secondaryMetric: VolumeMetric { metric == .tss ? .distance : .tss }
    private var secondaryActual: Double { metric == .tss ? actualKm : actualTSS }

    private func label(_ m: VolumeMetric, _ value: Double) -> String {
        switch m {
        case .tss:
            return "\(Int(value.rounded())) TSS"
        case .distance:
            return value >= 10
                ? "\(Int(value.rounded())) km"
                : String(format: "%.1f km", value)
        }
    }
}

