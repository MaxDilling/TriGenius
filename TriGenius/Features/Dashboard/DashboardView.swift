import SwiftUI
import Combine

// MARK: - Dashboard View
//
// The athlete's home screen. Card-based layout (see the design mockups):
//   • Header: greeting + calendar shortcut.
//   • Performance Insights: CTL / ATL / TSB stat cards — each tile taps through
//     to the full PMC chart (PerformanceInsightsView).
//   • Weekly Target (Volume): per-discipline rings, actual vs. target.
//   • AI insight: the coach's one-line read on the week, in the Apple
//     Intelligence look (its own tile).
//   • Up Next: today's completed + upcoming planned workouts, one tile.
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

    private var context: DashboardContext {
        DashboardContext(
            readSources: readSources,
            weeklyStructure: weeklyStructure,
            makeBackend: makeBackend,
            aiInsightEnabled: settings.aiDashboardInsight
        )
    }

    var body: some View {
        ScrollView {
            // One GlassEffectContainer so the dashboard's glass panes blend as a
            // single system instead of stacking independent glass layers.
            GlassEffectContainer(spacing: Theme.Spacing.l) {
                VStack(spacing: 20) {
                    if viewModel.isLoading && viewModel.pmc == nil {
                        ProgressView("Loading…").padding(.top, 60)
                    } else {
                        header
                        performanceInsights
                        weeklyTarget
                        aiInsightCard
                        upNext
                    }
                }
            }
            .padding()
        }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .refreshable { await viewModel.refresh(context: context) }
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
        // Toggling the AI summary on/off (Settings → Dashboard) — generate or clear
        // the insight without a full sync.
        .onChange(of: settings.aiDashboardInsight) {
            Task { await viewModel.load(context: context) }
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
        HStack(spacing: 12) {
            Text(initials)
                .font(.headline).foregroundStyle(.white)
                .frame(width: 48, height: 48)
                .background(Color.accentColor.gradient)
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(Date.now.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
                    .uppercased())
                    .font(.caption2).foregroundStyle(.secondary)
                Text(greeting).font(.title2.bold())
            }

            Spacer()

            NavigationLink {
                SettingsView(
                    brain: brain,
                    settings: settings,
                    memory: memory,
                    onBackendChanged: onBackendChanged
                )
            } label: {
                Image(systemName: "gearshape")
                    .font(.title3)
                    .frame(width: 44, height: 44)
                    .glassEffect(.regular, in: .circle)
            }
            .buttonStyle(.plain)
        }
    }

    private var greeting: String {
        if let name = athleteName, !name.isEmpty { return "Hi \(name)" }
        return "Hi there"
    }

    private var initials: String {
        guard let name = athleteName, !name.isEmpty else { return "🏃" }
        let parts = name.split(separator: " ")
        let letters = parts.prefix(2).compactMap { $0.first }
        return String(letters).uppercased()
    }

    // MARK: Performance Insights

    private var performanceInsights: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Performance Insights").font(.headline)

            // The whole stat-card row navigates to the full PMC chart — no
            // separate "Details" affordance; each card is the tap target.
            if let result = viewModel.pmc, let s = result.snapshot {
                HStack(spacing: 10) {
                    pmcLink(result) {
                        PMCStatCard(title: "Fitness", caption: "CTL", dot: .blue,
                                    value: Int(s.ctl.rounded()), delta: viewModel.ctlDelta,
                                    status: fitnessStatus(delta: viewModel.ctlDelta))
                    }
                    pmcLink(result) {
                        PMCStatCard(title: "Fatigue", caption: "ATL", dot: .pink,
                                    value: Int(s.atl.rounded()), delta: viewModel.atlDelta,
                                    status: fatigueStatus(atl: s.atl, ctl: s.ctl))
                    }
                    pmcLink(result) {
                        PMCStatCard(title: "Form", caption: "TSB", dot: .orange,
                                    value: Int(s.tsb.rounded()), delta: viewModel.tsbDelta,
                                    status: formStatus(tsb: s.tsb))
                    }
                }
            } else {
                Text("No training-load data yet. Sync your activities to see CTL / ATL / TSB.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .dashCard()
            }
        }
    }

    /// Wraps a stat card so the entire tile is the tap target for the PMC chart.
    private func pmcLink<Label: View>(_ result: PMCResult, @ViewBuilder label: () -> Label) -> some View {
        NavigationLink {
            PerformanceInsightsView(result: result)
        } label: {
            label()
        }
        .buttonStyle(.plain)
    }

    private func fitnessStatus(delta: Int) -> String {
        if delta > 1 { return "Productive build" }
        if delta < -1 { return "Declining" }
        return "Maintaining"
    }
    private func fatigueStatus(atl: Double, ctl: Double) -> String {
        atl > ctl ? "High load" : "Moderate load"
    }
    private func formStatus(tsb: Double) -> String {
        switch tsb {
        case ..<(-30):  return "Overreaching"
        case ..<(-10):  return "Optimal training"
        case ..<5:      return "Grey zone"
        case ..<20:     return "Fresh"
        default:        return "Very fresh"
        }
    }

    // MARK: Weekly Target (Volume)

    private var weeklyTarget: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Weekly Target").font(.headline)
                Spacer()
                VolumeMetricToggle(metric: $volumeMetric)
            }

            HStack(alignment: .top, spacing: 8) {
                ForEach(SportFamily.triathlon) { family in
                    let totals = viewModel.currentWeek?.totals(for: family) ?? VolumeTotals()
                    let target = viewModel.target(for: family)
                    let projection = viewModel.projection(for: family)
                    VolumeRing(family: family,
                               metric: volumeMetric,
                               actualTSS: totals.tss,
                               targetTSS: target.tss,
                               actualKm: totals.distanceKm,
                               targetKm: target.distanceKm,
                               projectedTSS: projection.projectedTSS,
                               projectedKm: projection.projectedKm)
                }
            }
        }
        .dashCard()
    }

    // MARK: AI insight

    // AI-generated insight (FEATURES.md "AI-generated dashboard insight") in its
    // own tile, styled in the Apple Intelligence look — the `apple.intelligence`
    // glyph and an iridescent gradient hairline around the card. A heuristic
    // fallback is surfaced instantly while the model line is generated.
    @ViewBuilder private var aiInsightCard: some View {
        if settings.aiDashboardInsight, let insight = viewModel.insight, !insight.isEmpty {
            let parsed = DashboardInsight.parse(insight)
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "apple.intelligence")
                    .font(.title2)
                    .foregroundStyle(Self.appleIntelligenceGradient)
                VStack(alignment: .leading, spacing: 10) {
                    Text(parsed.text)
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    // The coach's optional action link — a tappable chip that hands
                    // its message off to the chat (unsent), so the athlete can act
                    // on the gap the insight just named.
                    if let action = parsed.action {
                        insightActionChip(action)
                    }
                }
            }
            .dashCard()
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous)
                    .strokeBorder(Self.appleIntelligenceGradient, lineWidth: 1.5)
                    .opacity(0.9)
            )
            // Tapping the card carries its read of the week into the chat as a
            // pre-filled (unsent) prompt — same deterministic basis as the insight.
            .contentShape(Rectangle())
            .onTapGesture { router.openChat(prefill: viewModel.insightFollowUpPrompt) }
        }
    }

    /// Tappable chip for the insight's action link. Its own button consumes the tap
    /// so it routes the coach's specific message rather than the card's generic
    /// follow-up.
    private func insightActionChip(_ action: DashboardInsight.Action) -> some View {
        Button {
            router.openChat(prefill: action.message)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "wand.and.stars")
                Text(action.label)
            }
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, Theme.Spacing.m)
            .padding(.vertical, Theme.Spacing.s)
            .glassSurface(cornerRadius: Theme.Radius.l, tint: .accentColor)
        }
        .buttonStyle(.plain)
    }

    /// Apple Intelligence's signature iridescent gradient, reused for the glyph
    /// and the card's hairline border.
    private static let appleIntelligenceGradient = AngularGradient(
        colors: [.pink, .purple, .blue, .cyan, .orange, .pink],
        center: .center
    )

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
        VStack(alignment: .leading, spacing: 12) {
            Text("Up Next").font(.headline)

            let items = upNextItems
            if items.isEmpty {
                Text("No workouts logged or planned.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .dashCard()
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        if index > 0 {
                            Divider().padding(.leading, 64)
                        }
                        upNextRow(item)
                    }
                }
                .dashCard(padding: 0)
            }
        }
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
            HStack(spacing: 14) {
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
                        .foregroundStyle(.green)
                }
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 16)
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

// MARK: - PMC Stat Card

private struct PMCStatCard: View {
    let title: String
    let caption: String
    let dot: Color
    let value: Int
    let delta: Int
    let status: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Circle().fill(dot).frame(width: 7, height: 7)
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text("(\(caption))").font(.caption2).foregroundStyle(.tertiary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(value)").font(.title.bold())
                if delta != 0 {
                    HStack(spacing: 1) {
                        Image(systemName: delta > 0 ? "arrow.up" : "arrow.down")
                        Text("\(abs(delta))")
                    }
                    .font(.caption2).foregroundStyle(dot)
                }
            }
            Text(status).font(.caption2).foregroundStyle(dot)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashCard(padding: 12)
    }
}

// MARK: - Volume metric (TSS vs. distance)

/// Which metric the Weekly Target rings fill against and show on top. The other
/// metric drops to the secondary line below.
enum VolumeMetric: CaseIterable {
    case tss, distance

    var icon: String {
        switch self {
        case .tss:      return "bolt.fill"
        case .distance: return "ruler.fill"
        }
    }
}

/// The swap toggle in the Weekly Target header: two metric icons flanking a
/// swap glyph, the active one highlighted. Tapping flips the primary metric.
private struct VolumeMetricToggle: View {
    @Binding var metric: VolumeMetric

    var body: some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) {
                metric = metric == .tss ? .distance : .tss
            }
        } label: {
            HStack(spacing: 6) {
                segment(.tss)
                Image(systemName: "arrow.left.arrow.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                segment(.distance)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private func segment(_ m: VolumeMetric) -> some View {
        let active = metric == m
        return Image(systemName: m.icon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(active ? Color.white : Color.secondary)
            .frame(width: 26, height: 26)
            .background(Circle().fill(active ? Color.accentColor : Color.clear))
    }
}

// MARK: - Volume Ring

private struct VolumeRing: View {
    let family: SportFamily
    let metric: VolumeMetric
    let actualTSS: Double
    let targetTSS: Double
    let actualKm: Double
    let targetKm: Double
    /// Expected week close (completed + still-planned) for the active metric —
    /// rendered as a faded arc continuing past the solid "actual" fill.
    let projectedTSS: Double
    let projectedKm: Double

    private var actual: Double { metric == .tss ? actualTSS : actualKm }
    private var target: Double { metric == .tss ? targetTSS : targetKm }
    private var projected: Double { max(metric == .tss ? projectedTSS : projectedKm, actual) }

    // The ring fills against the active metric's weekly target.
    private var fraction: Double {
        target > 0 ? min(actual / target, 1) : 0
    }

    /// Where the projected close lands on the ring (always ≥ the actual fill).
    private var projectedFraction: Double {
        target > 0 ? min(projected / target, 1) : 0
    }

    /// True once the projected close still falls short of the target — the visible
    /// gap that signals an at-risk week.
    private var fallsShort: Bool { target > 0 && projectedFraction < 0.99 }

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle().stroke(Color.primary.opacity(0.10), lineWidth: 7)
                // Projection: the still-planned continuation beyond the completed
                // (solid) arc, up to the weekly target. Same 7pt radius as the
                // solid arc but dashed + lighter so it reads as "planned, not yet
                // done" rather than "done".
                if projectedFraction > fraction {
                    Circle()
                        .trim(from: fraction, to: projectedFraction)
                        .stroke(family.color.opacity(0.40),
                                style: StrokeStyle(lineWidth: 7, lineCap: .butt, dash: [2, 2]))
                        .rotationEffect(.degrees(-90))
                }
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(family.color, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: family.icon).font(.title3).foregroundStyle(family.color)
            }
            .frame(width: 60, height: 60)

            VStack(spacing: 1) {
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
        .frame(maxWidth: .infinity)
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

// MARK: - Helpers

/// Format minutes as "1h 05m" (or "45m" under an hour).
func durationHM(_ minutes: Double) -> String {
    let total = Int(minutes.rounded())
    let h = total / 60, m = total % 60
    return h > 0 ? "\(h)h \(String(format: "%02d", m))m" : "\(m)m"
}

// MARK: - Card styling

// Dashboard cards ride on real Liquid Glass (`glassEffect`) instead of a
// hand-rolled translucent fill. They're grouped under a single
// `GlassEffectContainer` in `DashboardView.body` so the panes blend as one
// glass system rather than stacking independent layers.
private struct DashCard: ViewModifier {
    var padding: CGFloat = Theme.Spacing.l
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassSurface(cornerRadius: Theme.Radius.l)
    }
}

extension View {
    func dashCard(padding: CGFloat = 16) -> some View { modifier(DashCard(padding: padding)) }
}

// MARK: - SportFamily presentation

extension SportFamily {
    var icon: String {
        switch self {
        case .swim: return "figure.pool.swim"
        case .bike: return "figure.outdoor.cycle"
        case .run: return "figure.run"
        case .strength: return "dumbbell"
        case .other: return "figure.mixed.cardio"
        }
    }

    var color: Color {
        switch self {
        case .swim: return .cyan
        case .bike: return .purple
        case .run: return .orange
        case .strength: return .gray
        case .other: return .green
        }
    }
}
