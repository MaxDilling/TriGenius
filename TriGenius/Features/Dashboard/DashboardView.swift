import SwiftUI
import Combine

// MARK: - Dashboard View
//
// The athlete's home screen. Card-based layout (see the design mockups):
//   • Header: greeting + calendar shortcut.
//   • Performance Insights: CTL / ATL / TSB stat cards → "Details" opens the
//     full PMC chart (PerformanceInsightsView).
//   • Weekly Target (Volume): per-discipline rings, actual vs. (dummy) target.
//   • Agenda: today's workouts (future/scheduled workouts → see FEATURES.md).
//
// Everything reads from the local DB via DashboardViewModel (source-agnostic).

struct DashboardView: View {
    let dataSource: DataSource
    var athleteName: String?
    let weeklyStructure: WeeklyStructure
    let trainingPlan: TrainingPlan
    @ObservedObject var memory: CoachMemory
    let makeBackend: () -> LLMBackend

    @State private var viewModel = DashboardViewModel()
    @State private var volumeMetric: VolumeMetric = .tss

    private var context: DashboardContext {
        DashboardContext(
            dataSource: dataSource,
            weeklyStructure: weeklyStructure,
            trainingPlan: trainingPlan,
            makeBackend: makeBackend
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
                        planBanner
                        performanceInsights
                        weeklyTarget
                        agenda
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
        // Plan/structure live in `coach_memory.json`, not the DB, so a coach edit
        // there bypasses the notification above. Reload when the plan signature
        // changes so the weekly targets recompute. `.onChange` fires after the new
        // value is in place, so `context` already carries the fresh plan.
        .onChange(of: planSignature) {
            Task { await viewModel.load(context: context) }
        }
    }

    /// Cheap, DB-free fingerprint of the inputs the weekly targets depend on, so a
    /// coach-driven plan/structure edit triggers a dashboard reload.
    private var planSignature: String {
        "\(trainingPlan.toDict())\n\(weeklyStructure.toDict())"
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
                CalendarView(dataSource: dataSource)
            } label: {
                Image(systemName: "calendar")
                    .font(.title3)
                    .frame(width: 44, height: 44)
                    .glassEffect(.regular, in: .circle)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Training-plan banner

    @ViewBuilder private var planBanner: some View {
        if TrainingPlanBanner.hasData(memory.trainingPlan) {
            NavigationLink {
                PlanView(memory: memory)
            } label: {
                TrainingPlanBanner(plan: memory.trainingPlan)
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
            HStack {
                Text("Performance Insights").font(.headline)
                Spacer()
                if let result = viewModel.pmc, result.snapshot != nil {
                    NavigationLink {
                        PerformanceInsightsView(result: result)
                    } label: {
                        HStack(spacing: 2) {
                            Text("Details")
                            Image(systemName: "chevron.right")
                        }
                        .font(.subheadline)
                    }
                }
            }

            if let s = viewModel.pmc?.snapshot {
                HStack(spacing: 10) {
                    PMCStatCard(title: "Fitness", caption: "CTL", dot: .blue,
                                value: Int(s.ctl.rounded()), delta: viewModel.ctlDelta,
                                status: fitnessStatus(delta: viewModel.ctlDelta))
                    PMCStatCard(title: "Fatigue", caption: "ATL", dot: .pink,
                                value: Int(s.atl.rounded()), delta: viewModel.atlDelta,
                                status: fatigueStatus(atl: s.atl, ctl: s.ctl))
                    PMCStatCard(title: "Form", caption: "TSB", dot: .orange,
                                value: Int(s.tsb.rounded()), delta: viewModel.tsbDelta,
                                status: formStatus(tsb: s.tsb))
                }
            } else {
                Text("No training-load data yet. Sync your activities to see CTL / ATL / TSB.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .dashCard()
            }
        }
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

            insightBox
        }
        .dashCard()
    }

    // AI-generated insight (FEATURES.md "AI-generated dashboard insight"), with a
    // heuristic fallback surfaced instantly while the model line is generated.
    @ViewBuilder private var insightBox: some View {
        if let insight = viewModel.insight, !insight.isEmpty {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.orange)
                Text(insight)
                    .font(.footnote)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
        }
    }

    // MARK: Agenda

    private var agenda: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Agenda").font(.headline)

            if viewModel.agendaDays.isEmpty {
                Text("No workouts logged or planned.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .dashCard()
            } else {
                ForEach(viewModel.agendaDays) { day in
                    agendaRow(day)
                }
            }
        }
    }

    /// One agenda day: the date stacked on the left, its workout cards on the right.
    @ViewBuilder private func agendaRow(_ day: AgendaDay) -> some View {
        HStack(alignment: .top, spacing: 14) {
            dateColumn(day.date)

            VStack(spacing: 12) {
                ForEach(day.completed) { record in
                    NavigationLink {
                        TrainingDetailView(record: record)
                    } label: {
                        AgendaCard(record: record)
                    }
                    .buttonStyle(.plain)
                }
                ForEach(day.planned) { planned in
                    NavigationLink {
                        PlannedWorkoutDetailView(workout: planned)
                    } label: {
                        PlannedAgendaCard(workout: planned)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func dateColumn(_ date: Date) -> some View {
        let isToday = Calendar.current.isDateInToday(date)
        return VStack(spacing: 2) {
            Text(date.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                .font(.caption).foregroundStyle(.secondary)
            Text(date.formatted(.dateTime.day()))
                .font(.title.bold())
                .foregroundStyle(isToday ? Color.accentColor : .primary)
        }
        .frame(width: 40)
        .padding(.top, 14)
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
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .glassEffect(.regular, in: .capsule)
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
    private var fallsShort: Bool { target > 0 && projectedFraction < 0.999 }

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
                                style: StrokeStyle(lineWidth: 7, lineCap: .butt, dash: [4, 4]))
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
                if secondaryActual > 0 {
                    Text(label(secondaryMetric, secondaryActual))
                        .font(.caption.weight(.semibold)).foregroundStyle(family.color)
                        .padding(.top, 2)
                }
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

// MARK: - Agenda Card

private struct AgendaCard: View {
    let record: ActivityRecord

    private var family: SportFamily { SportFamily(sportKey: record.sport) }
    private var details: [String: Any] {
        guard let data = record.detailsJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return obj
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            AgendaWorkoutHeader(icon: family.icon, color: family.color,
                                title: record.name, summary: summaryLine)

            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "checkmark")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.green)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.green.opacity(0.15)))

                VStack(alignment: .leading, spacing: 4) {
                    Text(timeLine).font(.subheadline).foregroundStyle(.secondary)
                    if let metrics = metricsLine {
                        Text(metrics).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .padding(.leading, 2)
        }
        .dashCard()
    }

    private var summaryLine: String {
        var parts = [durationHM(record.durationMinutes).uppercased()]
        if let tss = record.tss { parts.append("\(Int(tss.rounded())) TSS") }
        return parts.joined(separator: "  •  ")
    }

    /// Start time and elapsed duration, e.g. "07:30  –  1h 15m".
    private var timeLine: String {
        let duration = durationHM(record.durationMinutes)
        if let time = details["time"] as? String, !time.isEmpty {
            return "\(time)  –  \(duration)"
        }
        return duration
    }

    /// Distance and the headline intensity metric (power, else HR).
    private var metricsLine: String? {
        var parts: [String] = []
        if record.distanceKm > 0 { parts.append(String(format: "%.1f KM", record.distanceKm)) }
        if let power = avgPower { parts.append("\(power)W") }
        else if let hr = details["avg_hr"] as? Int { parts.append("\(hr) BPM") }
        return parts.isEmpty ? nil : parts.joined(separator: "  |  ")
    }

    private var avgPower: Int? {
        for key in ["cycling", "running"] {
            if let sub = details[key] as? [String: Any], let p = sub["avg_power_w"] as? Int { return p }
        }
        return nil
    }
}

// MARK: - Planned Agenda Card

/// A planned (not-yet-completed) workout in the Agenda — shows its target rather
/// than achieved metrics, the way TrainingPeaks previews a scheduled session.
private struct PlannedAgendaCard: View {
    let workout: ScheduledWorkoutRecord

    private var family: SportFamily { SportFamily(sportKey: workout.sport) }
    private var isEstimatedTSS: Bool { workout.targetTSS == nil }
    private var targetTSS: Double {
        workout.targetTSS ?? WeeklyTargets.estimatedTSS(family: family, minutes: workout.targetDurationMinutes)
    }

    var body: some View {
        AgendaWorkoutHeader(icon: family.icon, color: family.color,
                            title: workout.name, summary: summaryLine)
            .dashCard()
    }

    private var summaryLine: String {
        var parts: [String] = []
        if workout.targetDurationMinutes > 0 { parts.append(durationHM(workout.targetDurationMinutes).uppercased()) }
        if targetTSS > 0 {
            // A "~" marks an estimated TSS (no explicit target from the source).
            parts.append("\(isEstimatedTSS ? "~" : "")\(Int(targetTSS.rounded())) TSS")
        }
        return parts.isEmpty ? "Target not set" : parts.joined(separator: "  •  ")
    }
}

// MARK: - Agenda Workout Header

/// The shared top row of an Agenda card: sport icon, workout name, and a
/// "duration • TSS" summary line. Used by both completed and planned cards.
private struct AgendaWorkoutHeader: View {
    let icon: String
    let color: Color
    let title: String
    let summary: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(color)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline).lineLimit(1)
                Text(summary).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
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
