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
//   • Pinned: CTL / ATL / TSB + ramp-rate summary tiles → Fitness & Form detail; fitness vs
//     the ATP plan and this week's per-discipline rings → Plan tab; the heading's
//     "All Stats" → StatisticsView.
//   • Tissue Load: the structural load card → its grid / group detail.
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
    @State private var tissueMode: TissueCardMode = .sevenDays
    @State private var showsTissueGrid = false
    /// The group a tapped Tissue Load row opens.
    @State private var selectedGroup: TissueGroup?

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
        case .pinned: pinned
        case .tissueLoad: tissueLoad
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

    // MARK: Pinned

    private var pinned: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            SectionHeading("Pinned") {
                NavigationLink { StatisticsView(weeklyStructure: weeklyStructure) } label: {
                    HStack(spacing: Theme.Spacing.xs) {
                        Text("All Stats").font(.subheadline.weight(.semibold)).foregroundStyle(.tint)
                        Chevron()
                    }
                }
                .buttonStyle(.plain)
            }
            if let result = viewModel.pmc, result.snapshot != nil {
                LazyVGrid(columns: SummaryTile.columns(wide: wide.isWide, fill: 4), spacing: Theme.Spacing.m) {
                    PMCStatTiles(result: result, range: .oneMonth)
                }
                if !viewModel.ctlTrend.actual.isEmpty {
                    FitnessVsPlanCard(model: viewModel.ctlTrend)
                }
            } else {
                Text("No training-load data yet. Sync your activities to see CTL / ATL / TSB.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .contentCard()
            }
            if let week = viewModel.week, !week.visibleFamilies.isEmpty {
                WeeklyTargetCard(week: week)
            }
        }
    }

    // MARK: Tissue Load

    // A row opens its group — a conflict row's detail explains the spike and links
    // the session; the rest of the card opens the Tissue Load screen.
    @ViewBuilder private var tissueLoad: some View {
        if let model = viewModel.tissueCard {
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                SectionHeading("Tissue Load")
                // Wide layouts have the room for the whole grid, so they skip the
                // card's edit down to three rows.
                TissueLoadCard(mode: $tissueMode, model: model, chronic: viewModel.tissueChronic,
                               grid: wide.isWide ? viewModel.tissueGrid : nil,
                               onSelect: { selectedGroup = $0 },
                               onAskCoach: { router.openChat(prefill: $0) })
                    .contentShape(Rectangle())
                    .onTapGesture { showsTissueGrid = true }
            }
            .navigationDestination(isPresented: $showsTissueGrid) {
                if let input = viewModel.tissueInput {
                    TissueLoadScreen(input: input, onAskCoach: { router.openChat(prefill: $0) })
                }
            }
            .navigationDestination(item: $selectedGroup) { group in
                if let input = viewModel.tissueInput, let detail = TissueGroupDetailModel.make(group: group, input: input) {
                    TissueGroupDetail(model: detail, onAskCoach: { router.openChat(prefill: $0) })
                }
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
